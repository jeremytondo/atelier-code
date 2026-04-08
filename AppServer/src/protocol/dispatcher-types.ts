import type { SessionRecord } from "../server/session-state";
import type {
  JsonRpcErrorResponse,
  JsonRpcNotification,
  JsonRpcSuccessResponse,
} from "./types";

export interface DispatchContext {
  session: SessionRecord;
  notifications: {
    emit<TParams>(notification: JsonRpcNotification<TParams>): Promise<void>;
  };
}

// A dispatcher always returns a protocol response immediately and may attach
// follow-up async work for notifications or turn execution follow-up.
export interface DispatchOutcome {
  response: JsonRpcSuccessResponse | JsonRpcErrorResponse;
  followUp?: () => Promise<void>;
}
