import { createAppServer } from "@/app/server";

try {
  const server = await createAppServer();
  await server.start();
  await server.waitForStop();
} catch (error) {
  if (error instanceof Error) {
    console.error(error.message);
  } else {
    console.error("Unknown App Server startup failure");
  }

  process.exitCode = 1;
}
