import { type Static, Type } from "@sinclair/typebox";

export const RequestIdSchema = Type.Union([Type.String(), Type.Number()]);
export type RequestId = Static<typeof RequestIdSchema>;

export const ResponseIdSchema = Type.Union([RequestIdSchema, Type.Null()]);
export type ResponseId = Static<typeof ResponseIdSchema>;

export const ProtocolErrorDataSchema = Type.Object(
  {
    code: Type.String({ minLength: 1 }),
  },
  { additionalProperties: true },
);
export type ProtocolErrorData = Static<typeof ProtocolErrorDataSchema>;

export const ProtocolErrorSchema = Type.Object(
  {
    code: Type.Integer(),
    message: Type.String({ minLength: 1 }),
    data: Type.Optional(ProtocolErrorDataSchema),
  },
  { additionalProperties: false },
);
export type ProtocolError = Static<typeof ProtocolErrorSchema>;

export const ProtocolRequestSchema = Type.Object(
  {
    id: RequestIdSchema,
    method: Type.String({ minLength: 1 }),
    params: Type.Optional(Type.Unknown()),
  },
  { additionalProperties: false },
);
export type ProtocolRequest = Static<typeof ProtocolRequestSchema>;

export const ProtocolSuccessResponseSchema = Type.Object(
  {
    id: RequestIdSchema,
    result: Type.Unknown(),
  },
  { additionalProperties: false },
);
export type ProtocolSuccessResponse = Static<typeof ProtocolSuccessResponseSchema>;

export const ProtocolErrorResponseSchema = Type.Object(
  {
    id: ResponseIdSchema,
    error: ProtocolErrorSchema,
  },
  { additionalProperties: false },
);
export type ProtocolErrorResponse = Static<typeof ProtocolErrorResponseSchema>;

export const ProtocolNotificationSchema = Type.Object(
  {
    method: Type.String({ minLength: 1 }),
    params: Type.Optional(Type.Unknown()),
  },
  { additionalProperties: false },
);
export type ProtocolNotification = Static<typeof ProtocolNotificationSchema>;

export const InitializeCapabilitiesSchema = Type.Object(
  {
    experimentalApi: Type.Optional(Type.Boolean()),
    optOutNotificationMethods: Type.Optional(
      Type.Union([Type.Array(Type.String({ minLength: 1 })), Type.Null()]),
    ),
  },
  { additionalProperties: false },
);
export type InitializeCapabilities = Static<typeof InitializeCapabilitiesSchema>;

export const ClientInfoSchema = Type.Object(
  {
    name: Type.String({ minLength: 1 }),
    title: Type.Optional(Type.Union([Type.String({ minLength: 1 }), Type.Null()])),
    version: Type.String({ minLength: 1 }),
  },
  { additionalProperties: false },
);
export type ClientInfo = Static<typeof ClientInfoSchema>;

export const InitializeParamsSchema = Type.Object(
  {
    clientInfo: ClientInfoSchema,
    capabilities: Type.Optional(Type.Union([InitializeCapabilitiesSchema, Type.Null()])),
  },
  { additionalProperties: false },
);
export type InitializeParams = Static<typeof InitializeParamsSchema>;

export const InitializeResultSchema = Type.Object(
  {
    userAgent: Type.String({ minLength: 1 }),
  },
  { additionalProperties: false },
);
export type InitializeResult = Static<typeof InitializeResultSchema>;
