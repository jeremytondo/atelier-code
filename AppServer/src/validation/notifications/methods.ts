import type { SupportedNotificationMethod } from "../../protocol/types";

export function isSupportedNotificationMethod(
  method: string,
): method is SupportedNotificationMethod {
  return (
    method === "thread/started" ||
    method === "turn/started" ||
    method === "item/started" ||
    method === "item/agentMessage/delta" ||
    method === "item/completed" ||
    method === "turn/completed"
  );
}
