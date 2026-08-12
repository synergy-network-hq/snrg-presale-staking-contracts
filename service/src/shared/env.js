export function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required environment variable ${name}`);
  return value;
}

export function optional(name, fallback = '') {
  return process.env[name] || fallback;
}

export function integer(name, fallback = null) {
  const raw = process.env[name];
  if (!raw) {
    if (fallback !== null) return fallback;
    throw new Error(`Missing required integer environment variable ${name}`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 0) throw new Error(`Invalid integer ${name}`);
  return value;
}
