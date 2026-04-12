import { type Static, Type } from "@sinclair/typebox";

export const TurnStatusSchema = Type.Union([
  Type.Object(
    {
      type: Type.Literal("inProgress"),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    {
      type: Type.Literal("awaitingInput"),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    {
      type: Type.Literal("completed"),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    {
      type: Type.Literal("failed"),
      message: Type.Optional(Type.String({ minLength: 1 })),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    {
      type: Type.Literal("cancelled"),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    {
      type: Type.Literal("interrupted"),
    },
    { additionalProperties: false },
  ),
]);
export type TurnStatus = Static<typeof TurnStatusSchema>;

export const TurnSchema = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    status: TurnStatusSchema,
  },
  { additionalProperties: false },
);
export type Turn = Static<typeof TurnSchema>;

export const TurnItemSchema = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    kind: Type.String({ minLength: 1 }),
    rawItem: Type.Unknown(),
  },
  { additionalProperties: false },
);
export type TurnItem = Static<typeof TurnItemSchema>;

export const TurnStartParamsSchema = Type.Object(
  {
    threadId: Type.String({ minLength: 1 }),
    prompt: Type.String({ minLength: 1 }),
  },
  { additionalProperties: false },
);
export type TurnStartParams = Static<typeof TurnStartParamsSchema>;

export const TurnStartResultSchema = Type.Object(
  {
    turn: TurnSchema,
  },
  { additionalProperties: false },
);
export type TurnStartResult = Static<typeof TurnStartResultSchema>;

export const TurnStartedNotificationParamsSchema = Type.Object(
  {
    threadId: Type.String({ minLength: 1 }),
    turn: TurnSchema,
  },
  { additionalProperties: false },
);
export type TurnStartedNotificationParams = Static<typeof TurnStartedNotificationParamsSchema>;

export const TurnCompletedNotificationParamsSchema = TurnStartedNotificationParamsSchema;
export type TurnCompletedNotificationParams = Static<typeof TurnCompletedNotificationParamsSchema>;

export const ItemStartedNotificationParamsSchema = Type.Object(
  {
    threadId: Type.String({ minLength: 1 }),
    turnId: Type.String({ minLength: 1 }),
    item: TurnItemSchema,
  },
  { additionalProperties: false },
);
export type ItemStartedNotificationParams = Static<typeof ItemStartedNotificationParamsSchema>;

export const ItemCompletedNotificationParamsSchema = ItemStartedNotificationParamsSchema;
export type ItemCompletedNotificationParams = Static<typeof ItemCompletedNotificationParamsSchema>;

const createDeltaNotificationParamsSchema = () =>
  Type.Object(
    {
      threadId: Type.String({ minLength: 1 }),
      turnId: Type.String({ minLength: 1 }),
      itemId: Type.String({ minLength: 1 }),
      delta: Type.String(),
    },
    { additionalProperties: false },
  );

export const ItemMessageTextDeltaNotificationParamsSchema = createDeltaNotificationParamsSchema();
export type ItemMessageTextDeltaNotificationParams = Static<
  typeof ItemMessageTextDeltaNotificationParamsSchema
>;

export const ItemReasoningTextDeltaNotificationParamsSchema = createDeltaNotificationParamsSchema();
export type ItemReasoningTextDeltaNotificationParams = Static<
  typeof ItemReasoningTextDeltaNotificationParamsSchema
>;

export const ItemReasoningSummaryTextDeltaNotificationParamsSchema =
  createDeltaNotificationParamsSchema();
export type ItemReasoningSummaryTextDeltaNotificationParams = Static<
  typeof ItemReasoningSummaryTextDeltaNotificationParamsSchema
>;

export const ItemCommandExecutionOutputDeltaNotificationParamsSchema =
  createDeltaNotificationParamsSchema();
export type ItemCommandExecutionOutputDeltaNotificationParams = Static<
  typeof ItemCommandExecutionOutputDeltaNotificationParamsSchema
>;

export const ItemToolProgressNotificationParamsSchema = Type.Object(
  {
    threadId: Type.String({ minLength: 1 }),
    turnId: Type.String({ minLength: 1 }),
    itemId: Type.String({ minLength: 1 }),
    message: Type.String(),
  },
  { additionalProperties: false },
);
export type ItemToolProgressNotificationParams = Static<
  typeof ItemToolProgressNotificationParamsSchema
>;
