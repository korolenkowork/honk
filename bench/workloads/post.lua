-- wrk script for the POST /items workload: the same valid body each time.
wrk.method = "POST"
wrk.body = '{"name":"Egg","price":2.5}'
wrk.headers["Content-Type"] = "application/json"
