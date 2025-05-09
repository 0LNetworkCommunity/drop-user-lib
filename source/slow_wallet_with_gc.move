//////// SLOW WALLETS ////////
// Slow wallets have a limited amount available to transfer between accounts.
// Using Coins for network operations has no limit. Sending funds to DonorDirected wallets is also unlimited. Coins are free and clear user's property.
// Every epoch a new amount is made available (unlocked)
// slow wallets can use the normal payment and transfer mechanisms to move
// the unlocked amount.

module ol_framework::slow_wallet {
  use std::error;
  use std::event;
  use std::vector;
  use std::signer;
  use diem_framework::system_addresses;
  // use diem_framework::coin;
  use diem_framework::account;
  use ol_framework::libra_coin;
  use ol_framework::testnet;
  use ol_framework::sacred_cows;



  friend diem_framework::genesis;

  friend ol_framework::ol_account;
  friend ol_framework::transaction_fee;
  friend ol_framework::epoch_boundary;
  #[test_only]
  friend ol_framework::test_slow_wallet;
  #[test_only]
  friend ol_framework::test_pof;
  #[test_only]
  friend ol_framework::mock;
  #[test_only]
  friend ol_framework::test_boundary;


  /// genesis failed to initialized the slow wallet registry
  const EGENESIS_ERROR: u64 = 1;

  /// Maximum possible aggregatable coin value.
  const MAX_U64: u128 = 18446744073709551615;

    struct SlowWallet has key, drop {
        unlocked: u64,
        transferred: u64,
    }

    // the drip event at end of epoch
    struct DripEvent has drop, store {
      value: u64,
      users: u64,
    }

    struct SlowWalletList has key {
        list: vector<address>,
        drip_events: event::EventHandle<DripEvent>,
    }

    public(friend) fun initialize(framework: &signer){
      system_addresses::assert_ol(framework);
      if (!exists<SlowWalletList>(@ol_framework)) {
        move_to<SlowWalletList>(framework, SlowWalletList {
          list: vector::empty<address>(),
          drip_events: account::new_event_handle<DripEvent>(framework)
        });
      }
    }

    /// Users can change their account to slow, by calling the entry function
    /// Warning: this is permanent for the account. There's no way to
    /// reverse a "slow wallet".
    public entry fun user_set_slow(sig: &signer) acquires SlowWalletList {
      set_slow(sig);
    }

    /// implementation of setting slow wallet, allows contracts to call.
    fun set_slow(sig: &signer) acquires SlowWalletList {
      assert!(exists<SlowWalletList>(@ol_framework), error::invalid_argument(EGENESIS_ERROR));

        let addr = signer::address_of(sig);
        let list = get_slow_list();
        if (!vector::contains<address>(&list, &addr)) {
            let s = borrow_global_mut<SlowWalletList>(@ol_framework);
            vector::push_back(&mut s.list, addr);
        };

        if (!exists<SlowWallet>(signer::address_of(sig))) {
          move_to<SlowWallet>(sig, SlowWallet {
            unlocked: libra_coin::balance(addr),
            transferred: 0,
          });
        }
    }

    /// helper to get the unlocked and total balance. (unlocked, total)
    public(friend) fun unlocked_and_total(addr: address): (u64, u64) acquires SlowWallet{
      // this is a normal account, so return the normal balance
      let total = libra_coin::balance(addr);
      if (exists<SlowWallet>(addr)) {
        let s = borrow_global<SlowWallet>(addr);
        return (s.unlocked, total)
      };

      // if the account has no SlowWallet tracker, then everything is unlocked.
      (total, total)
    }

    /// VM causes the slow wallet to unlock by X amount
    /// @return tuple of 2
    /// 0: bool, was this successful
    /// 1: u64, how much was dripped
    public(friend) fun slow_wallet_epoch_drip(vm: &signer, amount: u64): (bool, u64) acquires
    SlowWallet, SlowWalletList{
      system_addresses::assert_ol(vm);
      garbage_collection();
      let list = get_slow_list();
      let len = vector::length<address>(&list);
      if (len == 0) return (false, 0);
      let accounts_updated: u64 = 0;
      let i = 0;
      while (i < len) {
        let addr = vector::borrow<address>(&list, i);
        let user_balance = libra_coin::balance(*addr);
        if (!exists<SlowWallet>(*addr)) continue; // NOTE: formal verifiction caught
        // this, not sure how it's possible

        let state = borrow_global_mut<SlowWallet>(*addr);

        // TODO implement this as a `spec`
        if ((state.unlocked as u128) + (amount as u128) >= MAX_U64) continue;

        let next_unlock = state.unlocked + amount;
        state.unlocked = if (next_unlock > user_balance) {
          // the user might have reached the end of the unlock period, and all
          // is unlocked
          user_balance
        } else {
          next_unlock
        };

        // it may be that some accounts were not updated, so we can't report
        // success unless that was the case.
        spec {
          assume accounts_updated + 1 < MAX_U64;
        };

        accounts_updated = accounts_updated + 1;

        i = i + 1;
      };

      emit_drip_event(vm, amount, accounts_updated);
      (accounts_updated==len, amount)
    }


    /// send a drip event notification with the totals of epoch
    fun emit_drip_event(root: &signer, value: u64, users: u64) acquires SlowWalletList {
        system_addresses::assert_ol(root);
        let state = borrow_global_mut<SlowWalletList>(@ol_framework);
        event::emit_event(
          &mut state.drip_events,
          DripEvent {
              value,
              users,
          },
      );
    }

    /// wrapper to both attempt to adjust the slow wallet tracker
    /// on the sender and recipient.
    /// if either account is not a slow wallet no tracking
    /// will happen on that account.
    /// Sould never abort.
    public(friend) fun maybe_track_slow_transfer(payer: address, recipient: address, amount: u64) acquires SlowWallet {
      maybe_track_unlocked_withdraw(payer, amount);
      maybe_track_unlocked_deposit(recipient, amount);
    }
    /// if a user spends/transfers unlocked coins we need to track that spend
    public(friend) fun maybe_track_unlocked_withdraw(payer: address, amount:
    u64) acquires SlowWallet {

      if (!exists<SlowWallet>(payer)) return;
      let s = borrow_global_mut<SlowWallet>(payer);

      spec {
        assume s.transferred + amount < MAX_U64;
      };

      s.transferred = s.transferred + amount;

      // THE VM is able to overdraw an account's unlocked amount.
      // in that case we need to check for zero.
      if (s.unlocked > amount) {
        s.unlocked = s.unlocked - amount;
      } else {
        s.unlocked = 0;
      }

    }

    /// when a user receives unlocked coins from another user, those coins
    /// always remain unlocked.
    public(friend) fun maybe_track_unlocked_deposit(recipient: address, amount: u64) acquires SlowWallet {
      if (!exists<SlowWallet>(recipient)) return;
      let state = borrow_global_mut<SlowWallet>(recipient);

      // TODO:
      // unlocked amount cannot be greater than total
      // this will not halt, since it's the VM that may call this.
      // but downstream code needs to check this
      state.unlocked = state.unlocked + amount;
    }

    /// Every epoch the system will drip a fixed amount
    /// @return tuple of 2
    /// 0: bool, was this successful
    /// 1: u64, how much was dripped
    public(friend) fun on_new_epoch(vm: &signer): (bool, u64) acquires SlowWallet, SlowWalletList {
      system_addresses::assert_ol(vm);
      slow_wallet_epoch_drip(vm, sacred_cows::get_slow_drip_const())
    }

    ///////// GETTERS ////////

    #[view]
    public fun is_slow(addr: address): bool {
      exists<SlowWallet>(addr)
    }
    #[view]
    /// Returns the amount of unlocked funds for a slow wallet.
    public fun unlocked_amount(addr: address): u64 acquires SlowWallet{
      // this is a normal account, so return the normal balance
      if (exists<SlowWallet>(addr)) {
        let s = borrow_global<SlowWallet>(addr);
        return s.unlocked
      };

      libra_coin::balance(addr)
    }

    #[view]
    /// Returns the amount of slow wallet transfers tracked
    public fun transferred_amount(addr: address): u64 acquires SlowWallet{
      // this is a normal account, so return the normal balance
      if (exists<SlowWallet>(addr)) {
        let s = borrow_global<SlowWallet>(addr);
        return s.transferred
      };
      0
    }

    #[view]
    // Getter for retrieving the list of slow wallets.
    public fun get_slow_list(): vector<address> acquires SlowWalletList{
      if (exists<SlowWalletList>(@ol_framework)) {
        let s = borrow_global<SlowWalletList>(@ol_framework);
        return *&s.list
      } else {
        return vector::empty<address>()
      }
    }

    #[view]
    // Getter for retrieving the list of slow wallets.
    public fun get_locked_supply(): u64 acquires SlowWalletList, SlowWallet{
      let list = get_slow_list();
      let sum = 0;
      vector::for_each(list, |addr| {
        let (u, t) = unlocked_and_total(addr);
        if (t > u) {
          sum = sum + (t-u);
        }
      });
      sum
    }

    //////// MIGRATIONS ////////

    /// private function which can only be called at genesis
    /// must apply the coin split factor.
    /// TODO: make this private with a public test helper
    fun fork_migrate_slow_wallet(
      framework: &signer,
      user: &signer,
      unlocked: u64,
      transferred: u64,
      // split_factor: u64,
    ) acquires SlowWallet, SlowWalletList {
      system_addresses::assert_diem_framework(framework);

      let user_addr = signer::address_of(user);
      if (!exists<SlowWallet>(user_addr)) {
        move_to<SlowWallet>(user, SlowWallet {
          unlocked,
          transferred,
        });

        update_slow_list(framework, user);
      } else {
        let state = borrow_global_mut<SlowWallet>(user_addr);
        state.unlocked = unlocked;
        state.transferred = transferred;
      }
    }

    /// private function which can only be called at genesis
    /// sets the list of accounts that are slow wallets.
    fun update_slow_list(
      framework: &signer,
      user: &signer,
    ) acquires SlowWalletList{
      system_addresses::assert_diem_framework(framework);
      if (!exists<SlowWalletList>(@ol_framework)) {
        initialize(framework); //don't abort
      };
      let state = borrow_global_mut<SlowWalletList>(@ol_framework);
      let addr = signer::address_of(user);
      if (!vector::contains(&state.list, &addr)) {
        vector::push_back(&mut state.list, addr);
      }
    }


    public(friend) fun hard_fork_sanitize(vm: &signer, user: &signer): u64 acquires
    SlowWallet {
      system_addresses::assert_vm(vm);
      let addr = signer::address_of(user);
      if (exists<SlowWallet>(addr)) {
        let (unlocked, total) = unlocked_and_total(addr);
        let _ = move_from<SlowWallet>(addr);
        if (total < unlocked) {
          // everything has been transferred out after unlocked
          return 0
        };
        return (total - unlocked)
      };
      0
    }

    public(friend) fun garbage_collection() acquires SlowWalletList {
      let state = borrow_global_mut<SlowWalletList>(@diem_framework);

      let to_keep = vector::filter(state.list, |e| {
        account::exists_at(*e)
      });

      state.list = to_keep;
    }

    //////// TEST HELPERS /////////

    #[test_only]
    public fun test_set_slow_wallet(
      vm: &signer,
      user: &signer,
      unlocked: u64,
      transferred: u64,
    ) acquires SlowWallet, SlowWalletList {
      set_slow_wallet_state(
        vm,
        user,
        unlocked,
        transferred
      )
    }

    ////////// SMOKE TEST HELPERS //////////
    // cannot use the #[test_only] attribute
    public entry fun smoke_test_vm_unlock(
      smoke_test_core_resource: &signer,
      user_addr: address,
      unlocked: u64,
      transferred: u64,
    ) acquires SlowWallet {

      system_addresses::assert_core_resource(smoke_test_core_resource);
      testnet::assert_testnet(smoke_test_core_resource);
      let state = borrow_global_mut<SlowWallet>(user_addr);
      state.unlocked = unlocked;
      state.transferred = transferred;
    }
}
