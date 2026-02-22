import { getSDK, initWalletSDK } from '../gateway/wallet-sdk.js';
import { logger } from '../../lib/logger.js';

type InstrumentId = { admin: string; id: string };
type LockedDetail = { amount: string; etaUnlockAt: string };
type TokenBalance = {
  instrumentId: InstrumentId;
  locked: string;
  unlocked: string;
  lockedDetails: LockedDetail[];
};

const compareInstrumentIds = (a: InstrumentId, b: InstrumentId) =>
  a.admin === b.admin && a.id === b.id;

/** Safe decimal addition for string amounts (avoids floating-point loss). */
function addAmounts(a: string, b: string): string {
  const [aInt = '0', aFrac = ''] = a.split('.');
  const [bInt = '0', bFrac = ''] = b.split('.');
  const maxFrac = Math.max(aFrac.length, bFrac.length);
  const aScaled = BigInt(aInt + aFrac.padEnd(maxFrac, '0'));
  const bScaled = BigInt(bInt + bFrac.padEnd(maxFrac, '0'));
  const sum = (aScaled + bScaled).toString();
  if (maxFrac === 0) return sum;
  const intPart = sum.slice(0, -maxFrac) || '0';
  const fracPart = sum.slice(-maxFrac).replace(/0+$/, '');
  return fracPart ? `${intPart}.${fracPart}` : intPart;
}

/**
 * Get token balances for a party using the Wallet SDK's listHoldingUtxos().
 *
 * Returns TokenBalance[] matching the existing backend format:
 *   [{ instrumentId: { admin, id }, locked, unlocked, lockedDetails }]
 *
 * The wallet extension expects this shape as BalanceSwapResponse[].
 */
export async function getTokenBalance(partyId: string): Promise<TokenBalance[]> {
  try {
    let sdk;
    try {
      sdk = getSDK();
    } catch {
      sdk = await initWalletSDK();
    }

    const holdings = await sdk.tokenStandard!.listHoldingUtxos(
      true, // includeLocked
      undefined, // limit
      undefined, // offset
      partyId, // query this specific party
    );

    // Aggregate holdings by instrumentId (same logic as canton-exchange-backend)
    const balances: TokenBalance[] = [];

    for (const h of holdings) {
      const view = h.interfaceViewValue;
      const instrumentId: InstrumentId = view.instrumentId ?? { admin: '', id: 'Unknown' };

      let idx = balances.findIndex((b) => compareInstrumentIds(b.instrumentId, instrumentId));
      if (idx < 0) {
        balances.push({ instrumentId, locked: '0', unlocked: '0', lockedDetails: [] });
        idx = balances.length - 1;
      }

      const amount = view.amount ?? '0';
      if (view.lock) {
        balances[idx].locked = addAmounts(balances[idx].locked, amount);
        balances[idx].lockedDetails.push({
          amount,
          etaUnlockAt: view.lock.expiresAt ?? '',
        });
      } else {
        balances[idx].unlocked = addAmounts(balances[idx].unlocked, amount);
      }
    }

    logger.info({ partyId, balanceCount: balances.length }, 'Token balances fetched via SDK');
    return balances;
  } catch (error) {
    logger.error({ partyId, error }, 'Failed to fetch token balance via SDK');
    return [];
  }
}

/**
 * Get token prices.
 * Currently returns static/cached prices.
 * Phase 2 will integrate with Chainlink and QCP for real-time pricing.
 */
export async function getTokenPrices() {
  return {
    prices: [
      { tokenId: 'Amulet', symbol: 'CC', price: '1.0', currency: 'USD' },
      { tokenId: 'CBTC', symbol: 'CBTC', price: '0.0', currency: 'USD' },
      { tokenId: 'USDCx', symbol: 'USDCx', price: '1.0', currency: 'USD' },
    ],
  };
}
