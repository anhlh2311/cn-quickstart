export const swaggerSpec = {
  openapi: '3.0.3',
  info: {
    title: 'Token Issuer API',
    version: '0.1.0',
    description:
      'Admin/testing backend for issuing tokens (CBTC, USDCx, etc.) on the Canton Network using the Utility package. ' +
      'Uses internal parties (participant holds keys) — no wallet extension or signing needed. ' +
      'No authentication required (local testing tool).',
  },
  servers: [{ url: 'http://localhost:3004', description: 'Local development' }],
  tags: [
    { name: 'Health', description: 'Liveness probe' },
    { name: 'Parties', description: 'Internal party allocation and management' },
    { name: 'Tokens', description: 'Token creation (InstrumentConfiguration + AllocationFactory)' },
    { name: 'Minting', description: 'Mint/allocate tokens to recipients' },
  ],
  paths: {
    '/healthz': {
      get: {
        tags: ['Health'],
        summary: 'Health check',
        responses: {
          '200': {
            description: 'Service is healthy',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: { status: { type: 'string', example: 'ok' } },
                },
              },
            },
          },
        },
      },
    },
    '/parties': {
      post: {
        tags: ['Parties'],
        summary: 'Allocate a new internal party',
        description:
          'Allocates an internal party on the Canton participant (participant holds the signing key). ' +
          'Grants CanActAs + CanReadAs rights to the admin user.',
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['partyHint', 'displayName'],
                properties: {
                  partyHint: {
                    type: 'string',
                    example: 'CBTC-NETWORK',
                    description: 'Unique hint for the party ID',
                  },
                  displayName: {
                    type: 'string',
                    example: 'CBTC Admin',
                    description: 'Human-readable display name',
                  },
                },
              },
            },
          },
        },
        responses: {
          '201': {
            description: 'Party allocated successfully',
            content: {
              'application/json': {
                schema: { $ref: '#/components/schemas/PartyResponse' },
              },
            },
          },
          '409': { description: 'Party hint already exists' },
          '500': { description: 'Internal server error' },
        },
      },
      get: {
        tags: ['Parties'],
        summary: 'List all parties',
        responses: {
          '200': {
            description: 'List of parties',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    code: { type: 'number', example: 200 },
                    data: {
                      type: 'array',
                      items: { $ref: '#/components/schemas/Party' },
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
    '/parties/{id}': {
      get: {
        tags: ['Parties'],
        summary: 'Get party by ID',
        parameters: [
          {
            name: 'id',
            in: 'path',
            required: true,
            schema: { type: 'string', format: 'uuid' },
          },
        ],
        responses: {
          '200': {
            description: 'Party found',
            content: {
              'application/json': {
                schema: { $ref: '#/components/schemas/PartyResponse' },
              },
            },
          },
          '404': { description: 'Party not found' },
        },
      },
    },
    '/tokens': {
      post: {
        tags: ['Tokens'],
        summary: 'Create a new token',
        description:
          'Creates InstrumentConfiguration and AllocationFactory contracts on the Canton ledger. ' +
          'Requires an active admin party. The AllocationFactory contract implements AllocationFactory, ' +
          'TransferFactory, and BurnMintFactory interfaces.',
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['adminPartyId', 'tokenId', 'displayName', 'symbol'],
                properties: {
                  adminPartyId: {
                    type: 'string',
                    format: 'uuid',
                    description: 'UUID of the admin party (from POST /parties)',
                  },
                  tokenId: {
                    type: 'string',
                    example: 'CBTC',
                    description: 'Token identifier (e.g., CBTC, USDCx)',
                  },
                  displayName: {
                    type: 'string',
                    example: 'Canton BTC',
                    description: 'Human-readable token name',
                  },
                  symbol: {
                    type: 'string',
                    example: 'CBTC',
                    description: 'Token symbol',
                  },
                },
              },
            },
          },
        },
        responses: {
          '201': {
            description: 'Token created successfully',
            content: {
              'application/json': {
                schema: { $ref: '#/components/schemas/TokenResponse' },
              },
            },
          },
          '400': { description: 'Admin party not found or not active' },
          '409': { description: 'Token already exists' },
          '500': { description: 'Internal server error' },
        },
      },
      get: {
        tags: ['Tokens'],
        summary: 'List all tokens',
        responses: {
          '200': {
            description: 'List of tokens',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    code: { type: 'number', example: 200 },
                    data: {
                      type: 'array',
                      items: { $ref: '#/components/schemas/Token' },
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
    '/tokens/{id}': {
      get: {
        tags: ['Tokens'],
        summary: 'Get token by ID or tokenId',
        description: 'Looks up by UUID first, then falls back to tokenId string (e.g., "CBTC").',
        parameters: [
          {
            name: 'id',
            in: 'path',
            required: true,
            schema: { type: 'string' },
            description: 'UUID or tokenId string',
          },
        ],
        responses: {
          '200': {
            description: 'Token found',
            content: {
              'application/json': {
                schema: { $ref: '#/components/schemas/TokenResponse' },
              },
            },
          },
          '404': { description: 'Token not found' },
        },
      },
    },
    '/tokens/{tokenId}/mint': {
      post: {
        tags: ['Minting'],
        summary: 'Mint tokens to recipients',
        description:
          'Exercises AllocationFactory_Allocate on the AllocationFactory contract to create ' +
          'new holdings for each recipient. The InstrumentConfiguration is included as a disclosed contract.',
        parameters: [
          {
            name: 'tokenId',
            in: 'path',
            required: true,
            schema: { type: 'string' },
            description: 'Token identifier (e.g., "CBTC")',
            example: 'CBTC',
          },
        ],
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: {
                type: 'object',
                required: ['recipients'],
                properties: {
                  recipients: {
                    type: 'array',
                    items: {
                      type: 'object',
                      required: ['partyId', 'amount'],
                      properties: {
                        partyId: {
                          type: 'string',
                          description: 'Full Canton party ID of the recipient',
                          example: 'alice::1220abc...',
                        },
                        amount: {
                          type: 'string',
                          description: 'Amount to mint (decimal string)',
                          example: '100.0',
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        },
        responses: {
          '200': {
            description: 'Mint results (per-recipient)',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    code: { type: 'number', example: 200 },
                    data: {
                      type: 'object',
                      properties: {
                        tokenId: { type: 'string' },
                        results: {
                          type: 'array',
                          items: { $ref: '#/components/schemas/MintResult' },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
          '400': { description: 'Token not active or missing contracts' },
          '404': { description: 'Token not found' },
          '500': { description: 'Internal server error' },
        },
      },
    },
    '/tokens/{tokenId}/mint-records': {
      get: {
        tags: ['Minting'],
        summary: 'List mint records for a token',
        parameters: [
          {
            name: 'tokenId',
            in: 'path',
            required: true,
            schema: { type: 'string' },
          },
        ],
        responses: {
          '200': {
            description: 'List of mint records',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    code: { type: 'number', example: 200 },
                    data: {
                      type: 'array',
                      items: { $ref: '#/components/schemas/MintRecord' },
                    },
                  },
                },
              },
            },
          },
        },
      },
    },
  },
  components: {
    schemas: {
      Party: {
        type: 'object',
        properties: {
          id: { type: 'string', format: 'uuid' },
          partyId: { type: 'string', description: 'Full Canton party ID (hint::namespace)' },
          partyHint: { type: 'string' },
          displayName: { type: 'string' },
          status: { type: 'string', enum: ['PENDING', 'ACTIVE', 'FAILED'] },
          createdAt: { type: 'string', format: 'date-time' },
        },
      },
      PartyResponse: {
        type: 'object',
        properties: {
          code: { type: 'number', example: 201 },
          data: { $ref: '#/components/schemas/Party' },
        },
      },
      Token: {
        type: 'object',
        properties: {
          id: { type: 'string', format: 'uuid' },
          tokenId: { type: 'string' },
          displayName: { type: 'string' },
          symbol: { type: 'string' },
          adminPartyId: { type: 'string', format: 'uuid' },
          cantonPartyId: { type: 'string' },
          instrumentConfigCid: { type: 'string', nullable: true },
          allocationFactoryCid: { type: 'string', nullable: true },
          status: { type: 'string', enum: ['PENDING', 'ACTIVE', 'FAILED'] },
          createdAt: { type: 'string', format: 'date-time' },
        },
      },
      TokenResponse: {
        type: 'object',
        properties: {
          code: { type: 'number', example: 201 },
          data: { $ref: '#/components/schemas/Token' },
        },
      },
      MintResult: {
        type: 'object',
        properties: {
          recipientPartyId: { type: 'string' },
          amount: { type: 'string' },
          status: { type: 'string', enum: ['PENDING', 'SUCCESS', 'FAILED'] },
          transactionId: { type: 'string', nullable: true },
          errorMessage: { type: 'string', nullable: true },
        },
      },
      MintRecord: {
        type: 'object',
        properties: {
          id: { type: 'string', format: 'uuid' },
          tokenId: { type: 'string' },
          recipientPartyId: { type: 'string' },
          amount: { type: 'string' },
          status: { type: 'string', enum: ['PENDING', 'SUCCESS', 'FAILED'] },
          transactionId: { type: 'string', nullable: true },
          errorMessage: { type: 'string', nullable: true },
          createdAt: { type: 'string', format: 'date-time' },
        },
      },
    },
  },
};
