#!/bin/bash

# Local integration tests. To be used by CI.
# See https://github.com/github/orchestrator/tree/doc/local-tests.md
#

# Usage: localtests/test/sh [mysql|sqlite] [filter]
# By default, runs all tests. Given filter, will only run tests matching given regep

tests_path=$(dirname $0)
setup_teardown_logfile=/tmp/orchestrator-setup-teardown.log
test_logfile=/tmp/orchestrator-test.log
test_outfile=/tmp/orchestrator-test.out
test_diff_file=/tmp/orchestrator-test.diff
test_query_file=/tmp/orchestrator-test.sql
test_restore_outfile=/tmp/orchestrator-test-restore.out
test_restore_diff_file=/tmp/orchestrator-test-restore.diff

exec_cmd() {
  echo "$@"
  command "$@" 1> $test_outfile 2> $test_logfile
  return $?
}

echo_dot() {
  echo -n "."
}


test_step() {
  local test_path
  test_path="$1"

  local test_name
  test_name="$2"

  local test_step_name
  test_step_name="$3"

  echo "Testing: $test_name/$test_step_name"

  if [ -f $test_path/setup ] ; then
    bash $test_path/setup 1> $setup_teardown_logfile 2>&1
    if [ $? -ne 0 ] ; then
      echo "ERROR $test_name/$test_step_name setup failed"
      cat $setup_teardown_logfile
      return 1
    fi
  fi

  if [ -f $test_path/run ] ; then
    bash $test_path/run 1> $test_outfile 2> $test_logfile
    execution_result=$?
  elif [ -f $test_path/skip_run ] ; then
    echo "+ skipping run"
  else
    echo "ERROR: neither 'run' nor 'skip_run' found in $test_path"
    return 1
  fi

  if [ -f $test_path/teardown ] ; then
    bash $test_path/teardown 1> $setup_teardown_logfile 2>&1
    if [ $? -ne 0 ] ; then
      echo "ERROR $test_name/$test_step_name teardown failed"
      cat $setup_teardown_logfile
      return 1
    fi
  fi
  if [ -f $test_path/teardown_redeploy ] ; then
    script/deploy-replication
  fi

  if [ -f $test_path/run ] ; then
    if [ -f $test_path/expect_failure ] ; then
      if [ $execution_result -eq 0 ] ; then
        echo "ERROR $test_name/$test_step_name execution was expected to exit on error but did not. cat $test_logfile"
        return 1
      fi
      if [ -s $test_path/expect_failure ] ; then
        # 'expect_failure' file has content. We expect to find this content in the log.
        expected_error_message="$(cat $test_path/expect_failure)"
        if grep -q "$expected_error_message" $test_logfile ; then
          return 0
        fi
        echo "ERROR $test_name/$test_step_name execution was expected to exit with error message '${expected_error_message}' but did not. cat $test_logfile"
        return 1
      fi
      # 'expect_failure' file has no content. We generally agree that the failure is correct
      return 0
    fi

    if [ $execution_result -ne 0 ] ; then
      echo "ERROR $test_name/$test_step_name execution failure. cat $test_logfile"
      return 1
    fi

    if [ -f $test_path/expect_output ] ; then
      diff -b $test_path/expect_output $test_outfile > $test_diff_file
      diff_result=$?
      if [ $diff_result -ne 0 ] ; then
        echo "ERROR $test_name/$test_step_name output does not match expect_output"
        echo "---"
        cat $test_diff_file
        echo "---"
        return 1
      fi
    fi
  fi # [ -f $test_path/run ]

  return 0
}


test_all() {
  test_pattern="${1:-.}"
  find $tests_path ! -path . -type d -mindepth 1 -maxdepth 1 | xargs ls -td1 | cut -d "/" -f 4 | egrep "$test_pattern" | while read test_name ; do
    # test steps:
    find "$tests_path/$test_name" ! -path . -type d -mindepth 1 -maxdepth 1 | sort | cut -d "/" -f 5 | while read test_step_name ; do
      [ "$test_step_name" == "." ] && continue
      test_step "$tests_path/$test_name/$test_step_name" "$test_name" "$test_step_name"
      if [ $? -ne 0 ] ; then
        echo "+ FAIL"
        return 1
      fi
      echo "+ pass"
    done
    if [ $? -ne 0 ] ; then
      return 1
    fi
    # test main step:
    test_step "$tests_path/$test_name" "$test_name" "main"
    if [ $? -ne 0 ] ; then
      echo "+ FAIL"
      return 1
    fi
    echo "+ pass"

    bash $tests_path/check_restore > $test_restore_outfile
    diff -b $tests_path/expect_restore $test_restore_outfile > $test_restore_diff_file
    diff_result=$?
    if [ $diff_result -ne 0 ] ; then
      echo
      echo "ERROR $test_name restore failure. cat $test_restore_diff_file"
      echo "---"
      cat $test_restore_diff_file
      echo "---"
      return 1
    fi
  done
}

main() {
  test_all "$@"
}

main "$@"
