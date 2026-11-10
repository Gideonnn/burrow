import type { TaskResult } from '@burrow/contracts';

// Counting a backlog is a scan, and runners ask after every piece.
export class Recent<T> {
  private readonly values = new Map<string, { at: number; value: T }>();

  constructor(private readonly ms: number) {}

  get(key: string, compute: () => T): T {
    const hit = this.values.get(key);
    if (hit && Date.now() - hit.at < this.ms) return hit.value;
    const value = compute();
    this.values.set(key, { at: Date.now(), value });
    return value;
  }

  forget(key: string) {
    this.values.delete(key);
  }
}

// One run per key at a time; callers meanwhile share its promise.
export function once<T>(
  running: Map<string, Promise<T>>,
  key: string,
  start: () => Promise<T>,
): Promise<T> {
  let run = running.get(key);
  if (!run) {
    run = start().finally(() => running.delete(key));
    running.set(key, run);
  }
  return run;
}

// A bot's answer travels from accept() to apply() inside the generic task
// result.
export function answerResult(summary: string, answer: unknown): TaskResult {
  return {
    summary,
    fields: { answer: JSON.stringify(answer) },
    ops: [],
    draft: null,
  };
}

export const answerOf = (result: TaskResult): unknown =>
  JSON.parse(result.fields.answer!);
