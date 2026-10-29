import * as net from "node:net";
import * as os from "node:os";

export interface SingleInstanceHandle {
  readonly primary: boolean;
  close(): Promise<void>;
}

export interface SingleInstanceOptions {
  name?: string;
  connectTimeoutMs?: number;
}

function instancePipeName(name: string): string {
  const user = os.userInfo().username.replace(/[^A-Za-z0-9_.-]/g, "_");
  const safeName = name.replace(/[^A-Za-z0-9_.-]/g, "_");
  return `\\\\.\\pipe\\${safeName}-${user}`;
}

function closeServer(server: net.Server | undefined): Promise<void> {
  if (!server || !server.listening) return Promise.resolve();
  return new Promise((resolve) => server.close(() => resolve()));
}

async function notifyPrimary(pipeName: string, timeoutMs: number): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const socket = net.createConnection(pipeName);
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("Timed out while contacting the running CliptoPulse instance"));
    }, timeoutMs);
    socket.once("connect", () => {
      socket.end("open\n");
    });
    socket.once("close", () => {
      clearTimeout(timer);
      resolve();
    });
    socket.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

export async function acquireSingleInstance(
  onActivate: () => void,
  options: SingleInstanceOptions = {}
): Promise<SingleInstanceHandle> {
  const pipeName = instancePipeName(options.name ?? "CliptoPulse-v1");
  const timeoutMs = options.connectTimeoutMs ?? 2_000;
  const server = net.createServer((socket) => {
    socket.setEncoding("utf8");
    let message = "";
    socket.on("data", (chunk) => {
      message += chunk;
      if (message.includes("\n")) socket.end();
    });
    socket.on("close", () => {
      if (message.trim() === "open") onActivate();
    });
  });

  const primary = await new Promise<boolean>((resolve, reject) => {
    const onError = (error: NodeJS.ErrnoException) => {
      server.removeListener("listening", onListening);
      if (error.code === "EADDRINUSE") {
        notifyPrimary(pipeName, timeoutMs).then(
          () => resolve(false),
          (notifyError) => reject(notifyError)
        );
      } else {
        reject(error);
      }
    };
    const onListening = () => {
      server.removeListener("error", onError);
      server.on("error", () => {
        // A listening named-pipe server can report aborted clients. The next
        // connection remains usable, so lifecycle errors are handled by main.
      });
      resolve(true);
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(pipeName);
  });

  if (!primary) {
    return {
      primary: false,
      close: async () => undefined
    };
  }

  return {
    primary: true,
    close: () => closeServer(server)
  };
}
