import { config } from '../config/index.js';
import { logger } from './logger.js';
import { getAdminToken } from './canton-auth.js';

const baseUrl = () => config.participantLedgerApiUrl;

async function cantonFetch(path: string, opts: RequestInit = {}): Promise<unknown> {
  const token = await getAdminToken();
  const url = `${baseUrl()}${path}`;

  logger.debug({ method: opts.method || 'GET', url }, 'Canton API request');

  const res = await fetch(url, {
    ...opts,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
      ...opts.headers,
    },
  });

  const text = await res.text();
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }

  if (!res.ok) {
    logger.error({ status: res.status, body, url }, 'Canton API error');
    throw new Error(`Canton API ${res.status}: ${typeof body === 'string' ? body : JSON.stringify(body)}`);
  }

  logger.debug({ status: res.status, url }, 'Canton API response OK');
  return body;
}

// ─── Party Management ───────────────────────────────────────────────

export interface PartyDetails {
  party: string;
  isLocal: boolean;
  displayName: string;
}

/**
 * Allocate an internal party on the Canton participant.
 * Internal = participant holds the signing key (no external keypair needed).
 */
export async function allocateInternalParty(
  partyIdHint: string,
  displayName: string,
): Promise<PartyDetails> {
  const result = (await cantonFetch('/v2/parties', {
    method: 'POST',
    body: JSON.stringify({
      partyIdHint,
      displayName,
      identityProviderId: '',
    }),
  })) as { partyDetails: PartyDetails };

  return result.partyDetails;
}

/**
 * Grant CanActAs + CanReadAs rights on a party to the admin user.
 */
export async function grantUserRights(
  userId: string,
  partyId: string,
): Promise<unknown> {
  return cantonFetch(`/v2/users/${encodeURIComponent(userId)}/rights`, {
    method: 'POST',
    body: JSON.stringify({
      userId,
      identityProviderId: '',
      rights: [
        { kind: { CanActAs: { value: { party: partyId } } } },
        { kind: { CanReadAs: { value: { party: partyId } } } },
      ],
    }),
  });
}

// ─── Ledger Commands ────────────────────────────────────────────────

export interface CreateCommand {
  CreateCommand: {
    templateId: string;
    createArguments: Record<string, unknown>;
  };
}

export interface ExerciseCommand {
  ExerciseCommand: {
    templateId: string;
    contractId: string;
    choice: string;
    choiceArgument: Record<string, unknown>;
  };
}

export interface DisclosedContract {
  templateId: string;
  contractId: string;
  createdEventBlob: string;
}

interface SubmitOptions {
  disclosedContracts?: DisclosedContract[];
  commandId?: string;
}

/**
 * Submit commands and wait for the transaction result.
 * For internal parties, no interactive signing is needed.
 */
export async function submitAndWait(
  commands: (CreateCommand | ExerciseCommand)[],
  actAs: string[],
  opts: SubmitOptions = {},
): Promise<unknown> {
  const commandId = opts.commandId || `ti-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

  const cmdBlock: Record<string, unknown> = {
    commands,
    actAs,
    userId: config.canton.adminUser,
    commandId,
  };

  if (opts.disclosedContracts?.length) {
    cmdBlock.disclosedContracts = opts.disclosedContracts;
  }

  const body = { commands: cmdBlock };

  return cantonFetch('/v2/commands/submit-and-wait-for-transaction', {
    method: 'POST',
    body: JSON.stringify(body),
  });
}

// ─── Contract Queries ───────────────────────────────────────────────

export interface ActiveContract {
  contractId: string;
  templateId: string;
  payload: Record<string, unknown>;
  createdEventBlob?: string;
}

/**
 * Get the current ledger end offset (needed for active-contracts queries).
 */
async function getLedgerEnd(): Promise<string> {
  const result = (await cantonFetch('/v2/state/ledger-end', {
    method: 'GET',
  })) as { offset: string };
  return result.offset;
}

/**
 * Query active contracts by party and template.
 * Uses the filtersByParty format matching the Canton v2 API.
 */
export async function queryActiveContracts(
  party: string,
  templateId: string,
  includeCreatedEventBlob = false,
): Promise<ActiveContract[]> {
  const offset = await getLedgerEnd();

  const result = (await cantonFetch('/v2/state/active-contracts', {
    method: 'POST',
    body: JSON.stringify({
      filter: {
        filtersByParty: {
          [party]: {
            cumulative: [
              {
                identifierFilter: {
                  TemplateFilter: {
                    value: {
                      templateId,
                      includeCreatedEventBlob,
                    },
                  },
                },
              },
            ],
          },
        },
      },
      verbose: false,
      activeAtOffset: offset,
    }),
  })) as { results?: Array<{ contractEntry?: Record<string, unknown> }> };

  if (!result.results) return [];

  const contracts: ActiveContract[] = [];
  for (const item of result.results) {
    // Canton v2 returns contractEntry with JsActiveContract or activeContract wrapper
    const entry = item.contractEntry;
    if (!entry) continue;

    const ac = (entry.JsActiveContract || entry.activeContract || entry) as Record<string, unknown>;
    const created = (ac.createdEvent || ac) as Record<string, unknown>;

    if (created?.contractId) {
      contracts.push({
        contractId: created.contractId as string,
        templateId: created.templateId as string,
        payload: (created.createArguments || {}) as Record<string, unknown>,
        createdEventBlob: created.createdEventBlob as string | undefined,
      });
    }
  }

  return contracts;
}

/**
 * Get the connected synchronizer ID (needed for some commands).
 */
export async function getConnectedSynchronizers(): Promise<string[]> {
  const result = (await cantonFetch('/v2/state/connected-synchronizers', {
    method: 'GET',
  })) as { connectedSynchronizers?: Array<{ synchronizerId: string }> };

  return (result.connectedSynchronizers || []).map((s) => s.synchronizerId);
}
