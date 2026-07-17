// A tiny stats module — the surface area Claude extends when you file issues.

export function mean(numbers) {
  if (!Array.isArray(numbers) || numbers.length === 0) {
    throw new Error("mean() requires a non-empty array");
  }
  return numbers.reduce((sum, n) => sum + n, 0) / numbers.length;
}

export function sum(numbers) {
  if (!Array.isArray(numbers)) {
    throw new Error("sum() requires an array");
  }
  return numbers.reduce((total, n) => total + n, 0);
}
