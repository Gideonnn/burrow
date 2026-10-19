import { EventEmitter } from 'node:events';

export type MailEvent =
  | { type: 'message.new'; mailboxId: string; messageId: string }
  | { type: 'message.changed'; mailboxId: string; messageId: string }
  | { type: 'message.removed'; mailboxId: string; messageId: string };

// In-process fan-out to the SSE streams of connected clients. Each stream
// filters on its own key's mailboxes.
export class EventBus {
  private readonly emitter = new EventEmitter().setMaxListeners(100);

  emit(event: MailEvent) {
    this.emitter.emit('event', event);
  }

  subscribe(listener: (event: MailEvent) => void): () => void {
    this.emitter.on('event', listener);
    return () => this.emitter.off('event', listener);
  }
}
