#!/usr/bin/env bash
# Checks the notification stack end to end without opening a browser.
#
# Run from this folder:  bash verify-notifications.sh
#
# Checks the stack used by NOTIFICATIONS-INTEGRATION.md. Read that first.
#
# Every check prints PASS or FAIL and the script exits non-zero if any failed,
# so it is safe to run before a demo or after pulling someone else's branch.
#
# Do not run this while `db:populate` is rebuilding the development database.
# Focused tests use the separate `doubtfire-notifications-test` database.

fails=0
api_url=${NOTIFICATIONS_API_URL:-http://localhost:3200}
web_url=${NOTIFICATIONS_WEB_URL:-http://localhost:4400}
mailpit_url=${NOTIFICATIONS_MAILPIT_URL:-http://localhost:8225}
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (wanted '$2', got '$3')"; fi
}

http() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

echo
echo "1. Containers"
for c in notifications-demo-api notifications-demo-sidekiq notifications-demo-web notifications-demo-db notifications-demo-redis notifications-demo-mailpit; do
  state=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo missing)
  check "$c is running" "true" "$state"
done
worker_queues=$(docker inspect -f '{{json .Config.Cmd}}' notifications-demo-sidekiq 2>/dev/null \
  | python3 -c 'import json,sys; command=json.load(sys.stdin); print(",".join(command[index + 1] for index, value in enumerate(command[:-1]) if value == "-q"))' \
  2>/dev/null || true)
check "worker consumes only the notification channel queues" "mailers,notifications" "$worker_queues"

# Compose considers a container started before Puma or the Angular server is
# necessarily ready to answer. A verifier run immediately after `up` or
# `restart` used to sample that short window and report false 000/500 failures.
# Poll all three routes together for up to one minute, then let the ordinary
# checks below report the last observed status if readiness never arrives.
api_status=000
web_status=000
proxy_status=000
for _ in {1..60}; do
  api_status=$(http "$api_url/api/settings/public")
  web_status=$(http "$web_url/")
  proxy_status=$(docker exec notifications-demo-web curl -s -o /dev/null -w '%{http_code}' \
    localhost:4200/api/settings/public 2>/dev/null || true)
  if [ "$api_status" = 200 ] && [ "$web_status" = 200 ] && [ "$proxy_status" = 200 ]; then
    break
  fi
  sleep 1
done

echo
echo "2. Ports answer"
check "api    :3200/api/settings/public" "200" "$api_status"
check "web    :4400"                     "200" "$web_status"
check "mailpit:8225"                     "200" "$(http "$mailpit_url/")"

echo
echo "3. Web can reach the api through its proxy"
check "web -> api" "200" "$proxy_status"

echo
echo "4. Mail goes to the catcher, not to a file  (EN-F02)"
check "delivery_method" "smtp" "$(docker exec notifications-demo-api printenv DF_SMTP_ADDRESS >/dev/null 2>&1 && echo smtp || echo file)"
check "smtp host"       "mailpit" "$(docker exec notifications-demo-api printenv DF_SMTP_ADDRESS 2>/dev/null | tr -d '\r')"
check "api sender"      "noreply@doubtfire.local" "$(docker exec notifications-demo-api printenv DF_INSTITUTION_EMAIL_SENDER 2>/dev/null | tr -d '\r')"
check "worker sender"   "noreply@doubtfire.local" "$(docker exec notifications-demo-sidekiq printenv DF_INSTITUTION_EMAIL_SENDER 2>/dev/null | tr -d '\r')"
check "api timezone"    "Australia/Melbourne" "$(docker exec notifications-demo-api printenv TZ 2>/dev/null | tr -d '\r')"
check "worker timezone" "Australia/Melbourne" "$(docker exec notifications-demo-sidekiq printenv TZ 2>/dev/null | tr -d '\r')"

echo
echo "5. Push prerequisites are mounted  (MN-F01)"
paths=$(curl -s "$api_url/api/swagger_doc" | python3 -c "import sys,json;print('yes' if '/api/push_subscriptions' in json.load(sys.stdin).get('paths',{}) else 'no')" 2>/dev/null)
check "/api/push_subscriptions in the api docs" "yes" "$paths"
table=$(docker exec notifications-demo-api bash -c "bundle exec rails runner 'puts \"R::\" + PushSubscription.table_exists?.to_s' 2>/dev/null" | grep -o 'R::.*' | cut -d: -f3)
check "push_subscriptions table exists" "true" "$table"

echo
echo "6. Push keys are loaded  (MN-F02)"
cfg=$(docker exec notifications-demo-api bash -c "bundle exec rails runner 'puts \"R::\" + PushNotificationService.configured?.to_s' 2>/dev/null" | grep -o 'R::.*' | cut -d: -f3)
check "PushNotificationService.configured?" "true" "$cfg"

echo
echo "7. Service worker is served  (MN-F03)"
ngsw_json=$(curl -fsS "$web_url/ngsw.json" \
  | python3 -c "import json,sys; json.load(sys.stdin); print('valid')" 2>/dev/null \
  || echo invalid)
ngsw_worker=$(curl -fsS "$web_url/ngsw-worker.js" \
  | python3 -c "import sys; data=sys.stdin.read(); head=data[:1000].lower(); print('valid' if len(data) > 10000 and '<!doctype html' not in head and 'ngsw' in data.lower() else 'invalid')" 2>/dev/null \
  || echo invalid)
check "ngsw.json is valid JSON" "valid" "$ngsw_json"
check "ngsw-worker.js is a real worker" "valid" "$ngsw_worker"

echo
echo "8. A comment really does send an email"
before=$(curl -s "$mailpit_url/api/v1/messages" | python3 -c "import sys,json;print(json.load(sys.stdin)['messages_count'])" 2>/dev/null)
token=$(docker exec notifications-demo-api bash -c "bundle exec rails runner \"u=User.find_by(username:'acain'); puts 'R::'+u.generate_authentication_token!.authentication_token\" 2>/dev/null" | grep -o 'R::.*' | cut -d: -f3)
# The text must be different every run. OnTrack drops a comment that duplicates
# the previous one on the same task and answers 403 "Comment duplicates last
# comment, so ignored" (task_comments_api.rb). A fixed string here makes the
# script pass, then fail, then pass, depending on what ran last. No notification
# is raised for a dropped duplicate, which is correct but worth knowing when a
# demo comment produces no email.
body="verify-notifications.sh check $(date +%s) $$"
code=$(curl -s -o /tmp/verify-comment-body -w '%{http_code}' \
  -X POST "$api_url/api/projects/2/task_def_id/1/comments/" \
  -H "Username: acain" -H "Auth-Token: $token" -H "Content-Type: application/json" \
  -d "{\"comment\":\"$body\"}")
check "POST a task comment" "201" "$code"
[ "$code" = "201" ] || echo "        response: $(head -c 200 /tmp/verify-comment-body)"
comment_id=$(python3 -c "import json; print(json.load(open('/tmp/verify-comment-body')).get('id', ''))" 2>/dev/null || true)
# Sidekiq polls asynchronously, so a fixed three-second sleep can observe the
# queue just before a healthy worker delivers. Poll for up to 20 seconds and
# finish immediately when Mailpit records the message.
after="$before"
for _ in {1..20}; do
  sleep 1
  after=$(curl -s "$mailpit_url/api/v1/messages" | python3 -c "import sys,json;print(json.load(sys.stdin)['messages_count'])" 2>/dev/null)
  [ "$after" -gt "$before" ] && break
done
if [ "$after" -gt "$before" ]; then
  pass "mailpit received the email ($before -> $after)"
else
  fail "mailpit did not receive an email ($before -> $after)"
fi

# Keep the seeded task visually clean for the recording. The caught email stays
# in Mailpit as verification evidence, but the synthetic comment and its in-app
# notification are removed together after delivery has been observed.
cleanup=$(docker exec -e VERIFY_COMMENT_ID="$comment_id" notifications-demo-api bash -c \
  "bundle exec rails runner 'comment = TaskComment.find_by(id: ENV[\"VERIFY_COMMENT_ID\"]); notification = comment && Notification.where(user_id: comment.recipient_id, event: \"task_comment_created\").where(created_at: (comment.created_at - 2.seconds)..(comment.created_at + 30.seconds)).order(id: :desc).first; notification&.destroy!; comment&.destroy!; puts \"R::\" + (!comment.nil?).to_s' 2>/dev/null" \
  | grep -o 'R::.*' | cut -d: -f3)
check "remove the synthetic comment and in-app notification" "true" "$cleanup"

echo
echo "9. The API queued cleanly and the worker has no failed channel delivery"
# Queue hand-off failures happen in the API process. SMTP and push delivery
# happen in Sidekiq, so worker logs and retry/dead sets are checked separately
# rather than assuming the API log can report an asynchronous delivery failure.
api_errs=$(docker logs --since 5m notifications-demo-api 2>&1 \
  | grep -Ec "Failed to queue notification (email|push)" \
  || true)
check "notification queue errors in the last 5 minutes" "0" "$api_errs"

worker_push_errs=$(docker logs --since 5m notifications-demo-sidekiq 2>&1 \
  | grep -Ec "Failed to push to subscription|Refusing to push to subscription" \
  || true)
check "push delivery errors in the last 5 minutes" "0" "$worker_push_errs"

retry_count=$(docker exec notifications-demo-sidekiq bash -c \
  "bundle exec rails runner 'require \"sidekiq/api\"; puts \"R::\" + Sidekiq::RetrySet.new.count { |job| job.klass == \"NotificationEmailJob\" }.to_s' 2>/dev/null" \
  | grep -o 'R::.*' | cut -d: -f3)
dead_count=$(docker exec notifications-demo-sidekiq bash -c \
  "bundle exec rails runner 'require \"sidekiq/api\"; puts \"R::\" + Sidekiq::DeadSet.new.count { |job| job.klass == \"NotificationEmailJob\" }.to_s' 2>/dev/null" \
  | grep -o 'R::.*' | cut -d: -f3)
push_retry_count=$(docker exec notifications-demo-sidekiq bash -c \
  "bundle exec rails runner 'require \"sidekiq/api\"; puts \"R::\" + Sidekiq::RetrySet.new.count { |job| job.klass == \"PushNotificationDeliveryJob\" }.to_s' 2>/dev/null" \
  | grep -o 'R::.*' | cut -d: -f3)
push_dead_count=$(docker exec notifications-demo-sidekiq bash -c \
  "bundle exec rails runner 'require \"sidekiq/api\"; puts \"R::\" + Sidekiq::DeadSet.new.count { |job| job.klass == \"PushNotificationDeliveryJob\" }.to_s' 2>/dev/null" \
  | grep -o 'R::.*' | cut -d: -f3)
check "notification email jobs waiting to retry" "0" "$retry_count"
check "notification email jobs in the dead set" "0" "$dead_count"
check "push notification jobs waiting to retry" "0" "$push_retry_count"
check "push notification jobs in the dead set" "0" "$push_dead_count"

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[32mAll prerequisite and email checks passed.\033[0m  Read the mail at %s\n' "$mailpit_url"
  printf 'Real Web Push still needs a signed-in browser/device verification.\n\n'
else
  printf '\033[31m%s check(s) failed.\033[0m  See doubtfire-deploy/RUNNING-LOCALLY.md\n\n' "$fails"
fi
exit "$fails"
