export type Result<T, E> =
  | Readonly<{
      ok: true;
      data: T;
    }>
  | Readonly<{
      ok: false;
      error: E;
    }>;

export const ok = <T>(data: T): Result<T, never> =>
  Object.freeze({
    ok: true,
    data,
  });

export const err = <E>(error: E): Result<never, E> =>
  Object.freeze({
    ok: false,
    error,
  });
