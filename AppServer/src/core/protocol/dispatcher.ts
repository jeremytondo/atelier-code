import type { Static, TSchema } from "@sinclair/typebox";
import type { ProtocolMethodError } from "@/core/protocol/errors";
import type { Result } from "@/core/shared";

export type ProtocolSession = Readonly<{
  isInitialized: () => boolean;
  markInitialized: () => Result<void, ProtocolMethodError>;
}>;

export type ProtocolMethodContext = Readonly<{
  connectionId: string;
  session: ProtocolSession;
}>;

export type ProtocolMethodHandler<TParams, TResult> = (
  input: ProtocolMethodContext &
    Readonly<{
      params: TParams;
    }>,
) => Promise<Result<TResult, ProtocolMethodError>> | Result<TResult, ProtocolMethodError>;

export type ProtocolMethodRegistration<
  TParamsSchema extends TSchema,
  TResultSchema extends TSchema,
> = Readonly<{
  method: string;
  paramsSchema: TParamsSchema;
  resultSchema: TResultSchema;
  handler: ProtocolMethodHandler<Static<TParamsSchema>, Static<TResultSchema>>;
}>;

export type RegisteredProtocolMethod = Readonly<{
  method: string;
  paramsSchema: TSchema;
  resultSchema: TSchema;
  handler: ProtocolMethodHandler<unknown, unknown>;
}>;

export type ProtocolDispatcher = Readonly<{
  registerMethod: <TParamsSchema extends TSchema, TResultSchema extends TSchema>(
    registration: ProtocolMethodRegistration<TParamsSchema, TResultSchema>,
  ) => void;
  getMethod: (method: string) => RegisteredProtocolMethod | undefined;
}>;

export const createProtocolDispatcher = (): ProtocolDispatcher => {
  const methods = new Map<string, RegisteredProtocolMethod>();

  const registerMethod: ProtocolDispatcher["registerMethod"] = (registration) => {
    if (methods.has(registration.method)) {
      throw new Error(`Protocol method already registered: ${registration.method}`);
    }

    const registeredMethod: RegisteredProtocolMethod = Object.freeze({
      method: registration.method,
      paramsSchema: registration.paramsSchema,
      resultSchema: registration.resultSchema,
      handler: registration.handler as ProtocolMethodHandler<unknown, unknown>,
    });

    methods.set(registration.method, registeredMethod);
  };

  return Object.freeze({
    registerMethod,
    getMethod: (method) => methods.get(method),
  });
};
