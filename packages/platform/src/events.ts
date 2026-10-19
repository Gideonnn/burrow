import { EventEmitter } from 'node:events';
import type { Access } from './access';

// What a client receives on the event stream, e.g. { type: 'message.new',
// mailboxId, messageId }.
export type EventData = { type: string } & Record<string, unknown>;

export type BurrowEvent = {
  data: EventData;
  // Decided by the module that emits it, per key: the stream only forwards
  // events the key may see.
  visibleTo: (access: Access) => boolean;
};

// In-process fan-out to the SSE streams of connected clients.
export class EventBus {
  private readonly emitter = new EventEmitter().setMaxListeners(100);

  emit(event: BurrowEvent) {
    this.emitter.emit('event', event);
  }

  // Everything a person (any of their keys) may see.
  emitTo(personIds: readonly string[], data: EventData) {
    this.emit({ data, visibleTo: (a) => personIds.includes(a.personId) });
  }

  subscribe(listener: (event: BurrowEvent) => void): () => void {
    this.emitter.on('event', listener);
    return () => this.emitter.off('event', listener);
  }
}
