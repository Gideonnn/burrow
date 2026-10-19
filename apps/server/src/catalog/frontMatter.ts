import { parse } from 'yaml';

export type FrontMatterDocument = {
  data: Record<string, unknown>;
  body: string;
};

export function splitFrontMatter(source: string): FrontMatterDocument {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(source);
  if (!match) throw new Error('missing front matter between --- lines');
  const data: unknown = parse(match[1]!);
  if (typeof data !== 'object' || data === null || Array.isArray(data)) {
    throw new Error('front matter must be a mapping');
  }
  return { data: data as Record<string, unknown>, body: match[2]!.trim() };
}
