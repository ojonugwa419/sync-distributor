import { Clarinet, Tx, Chain, Account, types } from 'https://deno.land/x/clarinet@v1.5.4/index.ts';
import { assertEquals } from 'https://deno.land/std@0.170.0/testing/asserts.ts';

Clarinet.test({
    name: "Sync Distributor: Create Transaction",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const sender = accounts.get('wallet_1')!;
        const recipient = accounts.get('wallet_2')!;

        const block = chain.mineBlock([
            Tx.contractCall('sync_distributor', 'create-transaction', [
                types.principal(recipient.address),
                types.uint(1000000),
                types.utf8('Test transaction')
            ], sender.address)
        ]);

        assertEquals(block.receipts.length, 1);
        assertEquals(block.height, 2);
        block.receipts[0].result.expectOk().expectUint(1);
    }
});

Clarinet.test({
    name: "Sync Distributor: Confirm Transaction",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const sender = accounts.get('wallet_1')!;
        const recipient = accounts.get('wallet_2')!;

        // First, create a transaction
        const createBlock = chain.mineBlock([
            Tx.contractCall('sync_distributor', 'create-transaction', [
                types.principal(recipient.address),
                types.uint(1000000),
                types.utf8('Test transaction')
            ], sender.address)
        ]);

        // Then, confirm the transaction
        const confirmBlock = chain.mineBlock([
            Tx.contractCall('sync_distributor', 'confirm-transaction', [
                types.uint(1)
            ], recipient.address)
        ]);

        assertEquals(confirmBlock.receipts.length, 1);
        confirmBlock.receipts[0].result.expectOk().expectBool(true);
    }
});

Clarinet.test({
    name: "Sync Distributor: Initiate Dispute",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const sender = accounts.get('wallet_1')!;
        const recipient = accounts.get('wallet_2')!;

        // Create a transaction
        const createBlock = chain.mineBlock([
            Tx.contractCall('sync_distributor', 'create-transaction', [
                types.principal(recipient.address),
                types.uint(1000000),
                types.utf8('Test transaction')
            ], sender.address)
        ]);

        // Initiate dispute
        const disputeBlock = chain.mineBlock([
            Tx.contractCall('sync_distributor', 'initiate-dispute', [
                types.uint(1),
                types.utf8('Dispute reason')
            ], sender.address)
        ]);

        assertEquals(disputeBlock.receipts.length, 1);
        disputeBlock.receipts[0].result.expectOk().expectBool(true);
    }
});

Clarinet.test({
    name: "Sync Distributor: Resolve Dispute Refund",
    async fn(chain: Chain, accounts: Map<string, Account>) {
        const sender = accounts.get('wallet_1')!;
        const recipient = accounts.get('wallet_2')!;

        // Create a transaction
        const createBlock = chain.mineBlock([
            Tx.contractCall('sync_distributor', 'create-transaction', [
                types.principal(recipient.address),
                types.uint(1000000),
                types.utf8('Test transaction')
            ], sender.address)
        ]);

        // Initiate dispute
        const disputeBlock = chain.mineBlock([
            Tx.contractCall('sync_distributor', 'initiate-dispute', [
                types.uint(1),
                types.utf8('Dispute reason')
            ], sender.address)
        ]);

        // Resolve dispute with refund
        const resolveBlock = chain.mineBlock([
            Tx.contractCall('sync_distributor', 'resolve-dispute-refund', [
                types.uint(1)
            ], sender.address)
        ]);

        assertEquals(resolveBlock.receipts.length, 1);
        resolveBlock.receipts[0].result.expectOk().expectBool(true);
    }
});