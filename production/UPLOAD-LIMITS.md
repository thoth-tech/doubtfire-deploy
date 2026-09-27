# Upload request and file limits

FILE-DP01 separates the proxy's total HTTP request limit from the API's file
policy. Nginx cannot decide whether a file is an authorized task submission,
chat attachment, valid format or safe document. Rails remains responsible for
all of those checks.

| Context | API limit | Boundary |
| --- | --- | --- |
| Task submission, per upload requirement | `DF_MAX_FILE_SIZE`, default 10,000,000 bytes | A file at the limit is permitted if its format is valid. |
| Task chat, one attachment per comment | 30,000,000 bytes | Must be nonempty and strictly below the limit. |
| Production proxy, entire request | `CLIENT_MAX_BODY_SIZE`, default `1g` (1,073,741,824 bytes) | Exactly the configured size is permitted; one byte more returns 413 before Rails. |

The existing production default already allows chat files plus multipart
overhead. No limit increase is needed. The total request budget also serves
multi-file task submissions and other API routes; it is not a new per-file
allowance. The production validator rejects unlimited limits and configurations
below `32m` (33,554,432 bytes), which leaves more than 3 MB of multipart headroom
above the existing chat boundary. A deployment with larger multi-file requests
must retain enough total request capacity for that workload.

Nginx returns `{"error":"...","code":"request_too_large"}` with HTTP 413.
Clients can display the `error` message without parsing an Nginx HTML page. API
413 responses continue to describe their narrower per-file limit.

## Repeatable proxy regression

Run from the repository root with Docker, Python 3 and OpenSSL available:

```sh
production/tests/validate_test.sh
python3 -B production/tests/nginx_upload_test.py
```

The test uses the **production Nginx template**, a disposable TLS certificate,
an isolated Docker network and a port bound only to localhost. It uses `32m` to
exercise the smallest supported configuration without transmitting a gigabyte.
It verifies Nginx syntax, forwards empty/small/29,999,999/30,000,000-byte file
requests including multipart overhead, accepts the exact 32 MiB request boundary,
and rejects one byte more with JSON 413 and the existing security headers.
Containers and the temporary network are removed at completion.

The upstream fixture only counts bytes. Its acceptance of empty and
30,000,000-byte files demonstrates that the proxy lets Rails make the decision;
it does **not** claim the API accepts them. Run the API upload tests and the
authenticated probe below for application policy. CI runs the configuration and
real Nginx checks on changes to production files.

## Direct API and proxied application regression

Use a disposable project/task and test user against the generic CSV attachment
API. Successful test comments are removed immediately. Set credentials in the
environment, then provide the same task's two endpoint URLs:

```sh
export UPLOAD_TEST_USERNAME=test-student
# Set UPLOAD_TEST_AUTH_TOKEN privately in the shell; do not save it in a report.
python3 -B production/tests/probe_upload_limits.py \
  --direct-url http://127.0.0.1:3000/api/projects/PROJECT/task_def_id/TASK/comments \
  --proxy-url https://ontrack.test.example/api/projects/PROJECT/task_def_id/TASK/comments
```

The probe prints sizes and status codes only. It checks empty files (400), small
and 29,999,999-byte files (201), and 30,000,000-byte files (413) both directly and
through the proxy. For an isolated `32m` proxy, add
`--proxy-limit-bytes 33554432` to also check the proxy-specific JSON 413.
TLS verification stays enabled and redirects are rejected to keep credentials
on the chosen endpoint. Record the API/web/deploy commits alongside the output.

The production request-size default is unchanged. This work does not deploy a
stack or provide production measurements; those require the actual deployment
configuration and its authorized test account.

## Verified local integration

The authenticated probe passed on 21 September 2026 against API commit
`6ca598ce` (the safe spreadsheet/chat attachment branch) and deploy commit
`8038777`. It used Rails 8.0.5.1 / Ruby 3.4.10 in test mode, a disposable MariaDB
database and project, and Nginx 1.30.4 with the production template and `32m`
request limit. HTTPS certificate verification remained enabled. No web client
was involved in these transport checks.

| File/request boundary | Direct API | Through Nginx |
| --- | --- | --- |
| Empty CSV | 400 | 400 |
| 1,024-byte CSV | 201 | 201 |
| 29,999,999-byte CSV | 201 | 201 |
| 30,000,000-byte CSV | 413 | 413 |
| 33,554,433-byte total request | Not an API file-policy case | 413, `request_too_large` |

The permitted near-limit CSV occupied 30,000,360 bytes as multipart data and
reached Rails through Nginx. Each successful test comment was deleted. The
[raw status/size results](tests/results/upload-boundaries-20260921.jsonl) contain
no credentials, filenames, account identifiers or private endpoint URLs.
