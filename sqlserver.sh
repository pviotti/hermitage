#!/bin/bash
# Prerequisites
# - start SQL Server locally, for instance by running:
#   docker run -e 'ACCEPT_EULA=Y' -e 'SA_PASSWORD=passWord123' -p 1433:1433 -d mcr.microsoft.com/mssql/server:2019-latest
# - install mssql-cli (https://github.com/dbcli/mssql-cli/)

if [ -z $1 ]; then
  echo -e "Please specify a test.\nOptions are: g0, g1a, g1b, g1c, otv, pmp, pmp-write, p4, g-single, g-single-dependencies, g-single-write-1, g-single-write-2, g2-item, g2, g2-two-edges"
  exit 2
elif [ -n $1 ]; then
  test=$1
fi

export PAGER=cat
tmux kill-session -t SQL > /dev/null 2>&1 || true
rm -rf /tmp/sql0.out /tmp/sql1.out
tmux new-session -d -n SQL -s SQL "mssql-cli -S localhost -U sa -P passWord123 2>&1 | tee /tmp/sql0.out"
tmux split-window -h -t SQL "mssql-cli -S localhost -U sa -P passWord123  2>&1 | tee /tmp/sql1.out"

tell() {
  tmux send-keys -t $1 "$2" Enter
  sleep 1 # FIXME makeshift synchronization between sessions
}

tell 0 "SET LOCK_TIMEOUT -1"
tell 1 "SET LOCK_TIMEOUT -1"

SETUP="drop database if exists test_lock
drop database if exists test_snap1
drop database if exists test_snap2
create database test_lock
create database test_snap1
create database test_snap2
alter database test_lock  set read_committed_snapshot  off
alter database test_lock  set allow_snapshot_isolation off
alter database test_snap1 set read_committed_snapshot  on
alter database test_snap1 set allow_snapshot_isolation off
alter database test_snap2 set read_committed_snapshot  off
alter database test_snap2 set allow_snapshot_isolation on
create table test_lock.dbo.test  (id int primary key, value int)
create table test_snap1.dbo.test (id int primary key, value int)
create table test_snap2.dbo.test (id int primary key, value int)
insert into test_lock.dbo.test  (id, value) values(1, 10), (2, 20)
insert into test_snap1.dbo.test (id, value) values(1, 10), (2, 20)
insert into test_snap2.dbo.test (id, value) values(1, 10), (2, 20)
print 'setup done'"

tell 0 "$SETUP"

echo -n "Waiting for setup to finish"
while grep  -e "^setup done" /tmp/sql0.out > /dev/null;
do echo -n "."; sleep 0.5; done
echo

case $test in
  "g0")
    echo "Running g0 test."
    tell 0 "set transaction isolation level read uncommitted; begin transaction"
    tell 1 "set transaction isolation level read uncommitted; begin transaction"
    tell 0 "update test_lock.dbo.test set value = 11 where id = 1"
    tell 1 "update test_lock.dbo.test set value = 12 where id = 1" # Blocks on lock request
    tell 0 "update test_lock.dbo.test set value = 21 where id = 2"
    tell 0 "commit"
    tell 0 "select * from test_lock.dbo.test" # Shows 1 => 12, 2 => 21
    tell 1 "update test_lock.dbo.test set value = 22 where id = 2"
    tell 1 "commit"
    tell 0 "select * from test_lock.dbo.test" # Shows 1 => 12, 2 => 22
    tell 1 "select * from test_lock.dbo.test" # Shows 1 => 12, 2 => 22
    ;;
  *)
    echo "Test not recognized."
    ;;
esac

tmux attach-session -t SQL