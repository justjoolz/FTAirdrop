import FungibleToken from "./dependencies/FungibleToken.cdc"

// Contract to allow a caller to deposit tokens 
// upload a list of addresses that can claim 
// and the amount they can claim
// caller sets time limit during which he cannot withdraw the tokens
// after the time limit expires the claiming ends and the owner can withdraw any remaining tokens
pub contract Airdrop {

    // drops by ID 
    access(contract) let drops: @{UInt64:Drop}

    // unique id for each drop
    access(contract) var nextDropID: UInt64

    pub event DropCreated(id: UInt64, address: Address, amount: UFix64)
    pub event DropClaimed(id: UInt64, address: Address, amount: UFix64)

    // Create Drop Function
    //
    // User calls functions to create an airdrop, they receive the controller in return they can store. 
    //
    pub fun createDrop(tokens: @FungibleToken.Vault, startTime: UFix64, duration: UFix64, ftReceiverCap: Capability<&{FungibleToken.Receiver}>, claims: {Address:UFix64}): @DropController {
        pre {
            startTime >= getCurrentBlock().timestamp : "Start time cannot be in the past!"
            duration >= 300.0 : "Start time must be at least 5 minutes in the future!"
            tokens.balance > 0.0 : "Must have tokens available to claim!"
        }
        // store amount for event
        let amount = tokens.balance

        // create drop resource
        let drop <- create Drop(tokens: <- tokens, startTime: startTime, duration: duration, ftReceiverCap: ftReceiverCap)

        // insert in dictionary
        self.drops[self.nextDropID] <-! drop

        // create controller resource
        let dropController <- create DropController(id: self.nextDropID)
        dropController.addClaims(addresses: claims)

        // increment id
        self.nextDropID = self.nextDropID + 1

        emit DropCreated(id: dropController.id, address: ftReceiverCap.address, amount: amount)

        // return controller for owner to save in their storage
        return <- dropController
    }

    access(contract) fun cleanup(_ key: UInt64) {
        destroy <- self.drops.remove(key: key)
    }

    // public function anyone can run to cleanup any expired drop resources 
    pub fun cleanAll() {
        let now = getCurrentBlock().timestamp
        for key in self.drops.keys {
            let drop = &self.drops[key] as &Drop
            if drop.endTime <= now {
                destroy <- self.drops.remove(key: key) // funds are returned in the resources destroy() function
            }
        }
    }

    // Check Available Claims
    //
    // Returns all claimable drop IDs with the details of the available claim  
    //
    pub fun checkAvailableClaims(address: Address): {UInt64: ClaimDetails} {
        let claimDetails: {UInt64: ClaimDetails} = {} 
        for key in self.drops.keys {
            let dropRef = &self.drops[key] as &Drop
            if dropRef.availableToClaimByAddress.containsKey(address) {
                claimDetails.insert(key: key, ClaimDetails(dropRef, address))
            }
        }
        return claimDetails
    }

    pub struct ClaimDetails {
        pub let ftType: Type 
        pub let amount: UFix64

        init(_ dropRef: &Drop, _ address: Address) {
            self.ftType = dropRef.vault.getType()
            self.amount = dropRef.availableToClaimByAddress[address]!
        }
    }

    // Claim Drop Function 
    //
    // Claims an amount for the address of the ft receiver cap provided 
    //
    pub fun claimDrop(dropID: UInt64, ftReceiverCap: Capability<&{FungibleToken.Receiver}>) {
        let dropRef = &self.drops[dropID] as &Drop
        let amount = dropRef.availableToClaimByAddress[ftReceiverCap.address]!
        assert(dropRef.availableToClaimByAddress[ftReceiverCap.address] != nil, message: "No funds available to claim for the receiver address provided")
        dropRef.claim(amount: amount, ftReceiverCap: ftReceiverCap)
        emit DropClaimed(id: dropID, address: ftReceiverCap.address, amount: amount)
    }

    // Drop Resource
    //
    // Stores the tokens for the drop, endTime, and the owners receiver cap in case of return
    //
    pub resource Drop {
        access(contract) let vault: @FungibleToken.Vault
        access(contract) let ftReceiverCap: Capability<&{FungibleToken.Receiver}>
        access(contract) let startTime: UFix64
        access(contract) let endTime: UFix64
        access(contract) let availableToClaimByAddress: {Address: UFix64}

        pub fun claim(amount:UFix64, ftReceiverCap: Capability<&{FungibleToken.Receiver}>) {
            let receiverRef = ftReceiverCap.borrow()
            receiverRef?.deposit(from: <- self.vault.withdraw(amount: amount))
            self.availableToClaimByAddress[ftReceiverCap.address] = self.availableToClaimByAddress[ftReceiverCap.address]! - amount
            // remove address from list if fully claimed
            if self.availableToClaimByAddress[ftReceiverCap.address] == 0.0 {
                self.availableToClaimByAddress[ftReceiverCap.address] = nil
            }
        }

        pub fun totalClaims(): UFix64 {
            var total = 0.0
            for key in self.availableToClaimByAddress.keys {
                total = total + self.availableToClaimByAddress[key]!
            }
            return total
        }

        init(tokens: @FungibleToken.Vault, startTime: UFix64, duration: UFix64, ftReceiverCap: Capability<&{FungibleToken.Receiver}>) {
            pre {
                duration >= 360.0
            }
            self.vault <- tokens
            self.startTime = startTime
            self.endTime = startTime + duration
            self.ftReceiverCap = ftReceiverCap
            self.availableToClaimByAddress = {}
        }

        destroy() {
            destroy self.vault
        }
    }


    // DropController resource
    //
    // Used to manage a drop
    //
    pub resource DropController {
        access(contract) let id: UInt64

        // addClaims function
        //
        // Drop owner can add a list of addresses and claim amounts 
        // Total must be less than funds deposited
        //
        pub fun addClaims(addresses: {Address: UFix64}) {
            let dropRef = &Airdrop.drops[self.id] as &Drop
            assert(getCurrentBlock().timestamp <= dropRef.startTime, message: "Cannot add addresses once claim has begun")
            var totalClaims = dropRef.totalClaims()
            for key in addresses.keys {
                totalClaims = totalClaims + dropRef.availableToClaimByAddress[key]!
                assert(totalClaims <= dropRef.vault.balance, message: "Total claims greater than balance available!")
                dropRef.availableToClaimByAddress.insert(key: key, addresses[key]!)
            }
        }

        // withdraw funds function
        //
        // once the drop has finished
        // owner can withdraw any unclaimed funds to their  ft receiver provided on creation
        //
        pub fun withdrawFunds() {
            let dropRef = &Airdrop.drops[self.id] as &Drop
            assert(getCurrentBlock().timestamp >= dropRef.endTime, message: "Drop has not ended yet!")
            let funds <- dropRef.vault.withdraw(amount: dropRef.vault.balance)
            dropRef.ftReceiverCap.borrow()?.deposit!(from: <- funds)
            Airdrop.cleanup(self.id)
        }

        // deposit funds function
        //
        // owner can deposit additional funds before the drop starts
        //
        pub fun depositFunds(funds: @FungibleToken.Vault) {
            let dropRef = &Airdrop.drops[self.id] as &Drop
            assert(getCurrentBlock().timestamp < dropRef.startTime, message: "Drop has already started!")
            dropRef.vault.deposit(from: <- funds)
        }

        // initalized with an ID to match the escrowed drop resource
        init(id: UInt64) {
            self.id = id
        }

        // owner can destroy their controller returning all funds to the provided ft receiver
        destroy () {
            let dropRef = &Airdrop.drops[self.id] as &Drop
            assert(getCurrentBlock().timestamp > dropRef.endTime, message: "Cannot destroy before endtime is reached")
            if dropRef.vault.balance > 0.0 {
                self.withdrawFunds()
            }
            assert(dropRef.vault.balance == 0.0, message: "Funds remaining in referenced drop, cannot destroy controller")
            Airdrop.drops[self.id] <-! nil
        }
    }

    init() {
        self.drops <- {}
        self.nextDropID = 0
    }
}