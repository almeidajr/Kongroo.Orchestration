// Cache demo load: a fixed arrival rate on Catalog's three cached reads through Kong, about 60 s.
// The summary's per-route p(50)/p(95) is the evidence; run once per HybridCache mode.
//
//   $token = (Invoke-RestMethod -Method POST -Uri http://localhost:8000/identity/tokens -ContentType application/json `
//       -Body (@{ username = "admin"; password = "<BOOTSTRAP_ADMIN_PASSWORD>" } | ConvertTo-Json)).accessToken
//   docker run --rm -e TOKEN=$token -e SHOWCASE=<ids printed by seed-games.ps1> -e "K6_SCRIPT=$(Get-Content -Raw load/catalog-cache.js)" `
//       --entrypoint sh grafana/k6:1.3.0 -c 'printf "%s" "$K6_SCRIPT" > /tmp/catalog-cache.js && k6 run /tmp/catalog-cache.js'
//
// The script travels in an env var because Windows-path bind mounts and piped stdin both fail on Rancher Desktop.
// Env (k6 reads the container's): TOKEN (required), GATEWAY (default http://host.docker.internal:8000; EKS: http://<kong-lb-hostname>),
// SHOWCASE (comma-separated game ids for the reviews read; default every game), RATE (requests/s per route), DURATION.
import http from 'k6/http';
import { check } from 'k6';

const gateway = __ENV.GATEWAY || 'http://host.docker.internal:8000';
const params = { headers: { Authorization: `Bearer ${__ENV.TOKEN}` } };

const route = (exec) => ({
  executor: 'constant-arrival-rate',
  exec,
  rate: Number(__ENV.RATE || 10),
  timeUnit: '1s',
  duration: __ENV.DURATION || '60s',
  preAllocatedVUs: 20,
  maxVUs: 200,
});

export const options = {
  scenarios: { games: route('games'), game: route('game'), reviews: route('reviews') },
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'max'],
  // Thresholds that always pass, only so the summary prints each route's own latency.
  thresholds: {
    'http_req_duration{scenario:games}': ['p(95)>=0'],
    'http_req_duration{scenario:game}': ['p(95)>=0'],
    'http_req_duration{scenario:reviews}': ['p(95)>=0'],
    checks: ['rate>0.99'],
  },
};

export function setup() {
  if (!__ENV.TOKEN) throw new Error('Pass a JWT with -e TOKEN=...');
  const response = http.get(`${gateway}/catalog/games`, params);
  if (response.status !== 200) throw new Error(`GET /catalog/games answered ${response.status}`);
  const ids = response.json().map((game) => game.id);
  if (ids.length === 0) throw new Error('No games: run scripts/seed-games.ps1 first');
  const showcase = __ENV.SHOWCASE ? __ENV.SHOWCASE.split(',') : ids;
  return { ids, showcase };
}

const pick = (items) => items[Math.floor(Math.random() * items.length)];
const get = (path) =>
  check(http.get(`${gateway}/catalog${path}`, params), { 'status is 200': (response) => response.status === 200 });

export function games() {
  get('/games');
}

export function game(data) {
  get(`/games/${pick(data.ids)}`);
}

export function reviews(data) {
  get(`/games/${pick(data.showcase)}/reviews`);
}
