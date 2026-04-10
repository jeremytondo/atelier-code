export const getErrorMessage = (error: unknown): string => {
  if (error instanceof AggregateError) {
    return error.errors.map(getErrorMessage).join("; ");
  }

  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
};
