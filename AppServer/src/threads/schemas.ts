import { type Static, Type } from "@sinclair/typebox";

export const ThreadExecutionStatusSchema = Type.Union([
  Type.Object(
    {
      type: Type.Literal("notLoaded"),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    {
      type: Type.Literal("idle"),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    {
      type: Type.Literal("active"),
      activeFlags: Type.Array(Type.String({ minLength: 1 })),
    },
    { additionalProperties: false },
  ),
  Type.Object(
    {
      type: Type.Literal("systemError"),
      message: Type.Optional(Type.String({ minLength: 1 })),
    },
    { additionalProperties: false },
  ),
]);
export type ThreadExecutionStatus = Static<typeof ThreadExecutionStatusSchema>;

export const ThreadSchema = Type.Object(
  {
    id: Type.String({ minLength: 1 }),
    preview: Type.String(),
    createdAt: Type.String({ minLength: 1 }),
    updatedAt: Type.String({ minLength: 1 }),
    name: Type.Union([Type.String({ minLength: 1 }), Type.Null()]),
    archived: Type.Boolean(),
    status: ThreadExecutionStatusSchema,
  },
  { additionalProperties: false },
);
export type Thread = Static<typeof ThreadSchema>;

export const ThreadListParamsSchema = Type.Object(
  {
    cursor: Type.Optional(Type.String({ minLength: 1 })),
    limit: Type.Optional(Type.Integer({ minimum: 1 })),
    archived: Type.Optional(Type.Boolean()),
  },
  { additionalProperties: false },
);
export type ThreadListParams = Static<typeof ThreadListParamsSchema>;

export const ThreadListResultSchema = Type.Object(
  {
    threads: Type.Array(ThreadSchema),
    nextCursor: Type.Union([Type.String({ minLength: 1 }), Type.Null()]),
  },
  { additionalProperties: false },
);
export type ThreadListResult = Static<typeof ThreadListResultSchema>;

export const ThreadReadParamsSchema = Type.Object(
  {
    threadId: Type.String({ minLength: 1 }),
    includeTurns: Type.Optional(Type.Boolean()),
  },
  { additionalProperties: false },
);
export type ThreadReadParams = Static<typeof ThreadReadParamsSchema>;

export const ThreadReadResultSchema = Type.Object(
  {
    thread: ThreadSchema,
  },
  { additionalProperties: false },
);
export type ThreadReadResult = Static<typeof ThreadReadResultSchema>;
