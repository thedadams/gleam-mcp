export function getEnv(name) {
  return process.env[name] ?? "";
}

export function sleepMs(duration) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, duration);
}
