# Pooly Node Recovery Notes

These notes document the lessons learned while bringing Node001, Node002, Node003, and Node004 into the Pooly Server Guard baseline.

## Node list

| Node | Host | IP |
|---|---|---|
| 001 | pooly-ssdnodes-001-toronto | 104.225.219.167 |
| 002 | pooly-ssdnodes-002-mumbai | 209.182.232.151 |
| 003 | pooly-ssdnodes-003-tokyo2 | 63.250.52.172 |
| 004 | pooly-ssdnodes-004-frankfurt | 208.87.129.34 |

## Important lesson: `systemctl --failed` is not enough

A service can be broken without appearing in:

```bash
systemctl --failed
```

Observed pattern:

```text
ActiveState=activating
SubState=auto-restart
Result=exit-code
ExecMainStatus=1
```

This happened with Kerrigan and Neoxa during rollout. Pooly Server Guard v0.4.3 adds `service-health` so scheduled checks catch this state.

## Kerrigan Plan-X / sapling cache corruption

Observed log pattern:

```text
FATAL: corrupted post-Plan-X-rollback state detected
- sapling commitment tree (sapling/)
Run kerrigand with -resetchainstate
```

Safe first repair:

```bash
sudo systemctl stop coin-kerrigan.service
sudo systemctl disable coin-kerrigan.service
sudo systemctl reset-failed coin-kerrigan.service

sudo -u poolyadmin /opt/pooly/bin/kerrigand-v1.2.6 \
  -datadir=/home/poolyadmin/.kerrigan \
  -conf=/home/poolyadmin/.kerrigan/kerrigan.conf \
  -resetchainstate
```

When the manual repair is accepting blocks and there are no recent fatal lines, stop the manual daemon and hand it back to systemd:

```bash
sudo pkill -TERM -f 'kerrigand-v1.2.6.*kerrigan'
sleep 20
sudo rm -f /home/poolyadmin/.kerrigan/.lock
sudo systemctl enable coin-kerrigan.service
sudo systemctl restart coin-kerrigan.service
```

Expected:

```text
ActiveState=active
SubState=running
Result=success
ExecMainStatus=0
```

## Kerrigan full chain-data reset fallback

Use only if `-resetchainstate` fails or logs show deeper block/LevelDB/EvoDB corruption.

Move data aside, do not delete immediately:

```bash
TS="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/home/poolyadmin/kerrigan-chain-backup-$TS"
sudo mkdir -p "$BACKUP"

for item in \
  blocks chainstate evodb indexes llmq sapling \
  .lock fee_estimates.dat mempool.dat peers.dat banlist.json netfulfilled.dat
do
  if sudo test -e "/home/poolyadmin/.kerrigan/$item"; then
    sudo mv "/home/poolyadmin/.kerrigan/$item" "$BACKUP/"
  fi
done

sudo chown -R poolyadmin:poolyadmin /home/poolyadmin/.kerrigan "$BACKUP"
sudo systemctl enable coin-kerrigan.service
sudo systemctl restart coin-kerrigan.service
```

## Neoxa bad `sporks.dat`

Observed log pattern:

```text
ERROR: Read: Deserialize or I/O error - CAutoFile::read: end of file
Error reading sporks.dat: Load: File format is unknown or invalid
Error: Failed to load sporks cache from /home/poolyadmin/.neoxacore/sporks.dat
```

A zero-byte or corrupt `sporks.dat` can be moved aside safely:

```bash
sudo systemctl stop coin-neoxa.service
sudo systemctl reset-failed coin-neoxa.service

TS="$(date -u +%Y%m%d-%H%M%S)"
sudo mv /home/poolyadmin/.neoxacore/sporks.dat \
  "/home/poolyadmin/.neoxacore/sporks.dat.bad-$TS"

sudo chown -R poolyadmin:poolyadmin /home/poolyadmin/.neoxacore
sudo systemctl enable coin-neoxa.service
sudo systemctl restart coin-neoxa.service
```

Expected:

```text
ActiveState=active
SubState=running
Result=success
ExecMainStatus=0
```

## Baseline refresh after service repair

After fixing a service that was previously missing from the running-service baseline:

```bash
sudo ~/GPTlogs/pooly-server-guard.sh init-state
sudo ~/GPTlogs/pooly-server-guard.sh watch
```

## Final all-node timer proof

After all four nodes have v0.4.3 installed and timers enabled, wait one full 30-minute timer cycle plus a few minutes, then run on each node:

```bash
hostname
date -u
systemctl list-timers --all | grep pooly-server-guard || true
sudo systemctl status pooly-server-guard-watch.timer --no-pager
sudo systemctl status pooly-server-guard-watch.service --no-pager
sudo journalctl -u pooly-server-guard-watch.service -n 180 --no-pager
sudo systemctl --failed --no-pager
```

Expected on each node:

```text
UPDATE RESULT: PASS
RESULT: PASS
BASELINE RESULT: PASS
PORT RESULT: PASS
KEYS RESULT: PASS
SSHD DRIFT RESULT: PASS
UFW DRIFT RESULT: PASS
SERVICE RESULT: PASS
SERVICE HEALTH RESULT: PASS
0 loaded units listed.
status=0/SUCCESS
pooly-server-guard-watch.timer active (waiting)
```
