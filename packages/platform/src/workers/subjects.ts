import type { Subject, TaskResult } from '@burrow/contracts';
import type { Access } from '../access';
import type { TaskRow } from './tasks';

export type PromptContext = {
  ownerName: string;
  instructions: string;
  language: string;
  // The opening line, e.g. 'Run the routine "Facturen" for'.
  task: string;
};

// A kind of thing a module owns that tasks and routines can be about: a mail
// message, a recording. The module decides who sees it, what an agent may
// read about it, and what applying a result does.
export type SubjectType = {
  type: string;
  visible: (access: Access, id: string) => boolean;
  // The full prompt for an agent: trusted facts first, the subject's own
  // (untrusted) content fenced. Undefined when the subject is gone.
  prompt: (id: string, context: PromptContext) => string | undefined;
  apply?: (id: string, result: TaskResult, task: TaskRow) => Promise<void>;
};

export class Subjects {
  private readonly types = new Map<string, SubjectType>();

  register(type: SubjectType) {
    if (this.types.has(type.type)) {
      throw new Error(`subject type "${type.type}" is registered twice`);
    }
    this.types.set(type.type, type);
  }

  get(type: string): SubjectType | undefined {
    return this.types.get(type);
  }

  // A subject of an unknown type is invisible, never visible by default.
  visible(access: Access, subject: Subject): boolean {
    return this.types.get(subject.type)?.visible(access, subject.id) ?? false;
  }
}
