import { v4 as uuid } from 'uuid';
import { logger } from './logger.js';

interface JsonRpcRequest {
  jsonrpc: '2.0';
  id: string;
  method: string;
  params?: unknown;
}

interface JsonRpcResponse<T = unknown> {
  jsonrpc: '2.0';
  id: string;
  result?: T;
  error?: {
    code: number;
    message: string;
    data?: unknown;
  };
}

export class JsonRpcError extends Error {
  constructor(
    public readonly code: number,
    message: string,
    public readonly data?: unknown,
  ) {
    super(message);
    this.name = 'JsonRpcError';
  }
}

/**
 * Send a JSON-RPC 2.0 request to a remote endpoint.
 */
export async function jsonRpcCall<T = unknown>(
  url: string,
  method: string,
  params?: unknown,
  bearerToken?: string,
): Promise<T> {
  const id = uuid();
  const body: JsonRpcRequest = { jsonrpc: '2.0', id, method, params };

  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (bearerToken) {
    headers['Authorization'] = `Bearer ${bearerToken}`;
  }

  logger.debug({ url, method, id }, 'JSON-RPC call');

  const response = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    throw new Error(`JSON-RPC HTTP error: ${response.status} ${response.statusText}`);
  }

  const json = (await response.json()) as JsonRpcResponse<T>;

  if (json.error) {
    logger.error({ url, method, id, error: json.error }, 'JSON-RPC error');
    throw new JsonRpcError(json.error.code, json.error.message, json.error.data);
  }

  return json.result as T;
}
