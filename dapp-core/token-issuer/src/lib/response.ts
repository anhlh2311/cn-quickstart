import type { Response } from 'express';

interface ApiResponse<T = unknown> {
  code: number;
  data: T;
  metadata?: Record<string, unknown>;
}

export function ok<T>(res: Response, data: T, metadata?: Record<string, unknown>): void {
  const response: ApiResponse<T> = { code: 200, data, ...(metadata && { metadata }) };
  res.status(200).json(response);
}

export function created<T>(res: Response, data: T): void {
  const response: ApiResponse<T> = { code: 201, data };
  res.status(201).json(response);
}

export function err(res: Response, code: number, message: string): void {
  const response: ApiResponse<{ message: string }> = { code, data: { message } };
  res.status(code).json(response);
}
