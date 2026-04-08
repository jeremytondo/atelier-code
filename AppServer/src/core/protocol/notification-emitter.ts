import { assertProtocolNotification } from "./message-assertions";
import type { JsonRpcNotification } from "./types";

export interface ProtocolNotificationTarget {
  emit<TParams>(
    notification: JsonRpcNotification<TParams>,
  ): Promise<void> | void;
}

export function createProtocolNotificationEmitter(
  target: ProtocolNotificationTarget,
): ProtocolNotificationTarget {
  return {
    emit<TParams>(notification: JsonRpcNotification<TParams>) {
      return target.emit(assertProtocolNotification(notification));
    },
  };
}
