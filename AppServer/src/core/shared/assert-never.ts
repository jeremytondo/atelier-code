export const assertNever = (
  value: never,
  message = "Unhandled discriminated union member",
): never => {
  throw new Error(`${message}: ${JSON.stringify(value)}`);
};
