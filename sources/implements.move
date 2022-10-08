/// Copyright 2022 OmniBTC Authors. Licensed under Apache-2.0 License.

/// TODO: Refactor after dealing with these issues
/// https://github.com/MystenLabs/sui/issues/4894
/// https://github.com/MystenLabs/sui/issues/4202

module swap::implements {
  use sui::object::{Self, ID, UID};
  use sui::coin::{Self, Coin};
  use sui::balance::{Self, Supply, Balance};
  use sui::tx_context::{Self, TxContext};
  use sui::sui::SUI;
  use sui::transfer;

  friend swap::controller;
  friend swap::interface;

  /// For when supplied Coin is zero.
  const ERR_ZERO_AMOUNT: u64 = 0;
  /// For when someone tries to swap in an empty pool.
  const ERR_RESERVES_EMPTY: u64 = 1;
  /// For when someone attempts to add more liquidity than u128 Math allows.
  const ERR_POOL_FULL: u64 = 2;
  /// Insuficient amount in Sui reserves.
  const ERR_INSUFFICIENT_SUI: u64 = 3;
  /// Insuficient amount in Token reserves.
  const ERR_INSUFFICIENT_TOKEN: u64 = 4;
  const ERR_DIVIDE_BY_ZERO: u64 = 5;
  const ERR_OVERLIMIT_SUI: u64 = 6;
  /// Amount out less than minimum.
  const ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM: u64 = 7;

  const FEE_MULTIPLIER: u64 = 30;
  const FEE_SCALE: u64 = 10000;

  /// The max value that can be held in one of the Balances of
  /// a Pool. U64 MAX / FEE_SCALE
  const MAX_POOL_VALUE: u64 = {
    18446744073709551615 / 10000
  };

  /// The Pool token that will be used to mark the pool share
  /// of a liquidity provider. The parameter `T` is for the
  /// coin held in the pool.
  /// eg. LP<Token> is SUI-Token pair.
  struct LP<phantom T> has drop {}

  /// The pool with exchange.
  struct Pool<phantom T> has key {
    id: UID,
    global: ID,
    sui: Balance<SUI>,
    token: Balance<T>,
    lp_supply: Supply<LP<T>>,
  }

  /// The global config
  struct Global has key {
    id: UID,
    pool_account: address,
    has_paused: bool,
  }

  /// init global config
  fun init(ctx: &mut TxContext) {
    let global = Global {
      id: object::new(ctx),
      pool_account: tx_context::sender(ctx),
      has_paused: false,
    };

    transfer::share_object(global)
  }

  public fun global_id<T>(pool: &Pool<T>): ID {
    pool.global
  }

  public(friend) fun id(global: &Global):ID {
    object::uid_to_inner(&global.id)
  }

  public(friend) fun pause(global: &mut Global) {
    global.has_paused = true
  }

  public(friend) fun resume(global: &mut Global) {
    global.has_paused = false
  }

  public(friend) fun is_emergency(global: &Global):bool {
    global.has_paused
  }

  public(friend) fun pool_account(global: &Global):address {
    global.pool_account
  }

  /// Create Sui-T pool
  public fun create_pool<T>(
    global: &Global,
    token: Coin<T>,
    sui: Coin<SUI>,
    ctx: &mut TxContext
  ): Coin<LP<T>> {
    let sui_amount = coin::value(&sui);
    let token_amount = coin::value(&token);

    assert!(sui_amount > 0 && token_amount > 0, ERR_ZERO_AMOUNT);
    assert!(sui_amount < MAX_POOL_VALUE && token_amount < MAX_POOL_VALUE, ERR_POOL_FULL);

    // Initial share of LP is the a * b
    let share = sui_amount * token_amount;
    let lp_supply = balance::create_supply(LP<T> {});
    let lp = balance::increase_supply(&mut lp_supply, share);

    transfer::share_object(Pool {
      id: object::new(ctx),
      token: coin::into_balance(token),
      sui: coin::into_balance(sui),
      lp_supply,
      global: object::uid_to_inner(&global.id)
    });

    coin::from_balance(lp, ctx)
  }

  /// Add liquidity to the `Pool`. Sender needs to provide both
  /// `Coin<SUI>` and `Coin<T>`, and in exchange he gets `Coin<LP>` -
  /// liquidity provider tokens.
  public fun add_liquidity<T>(
    pool: &mut Pool<T>,
    sui: Coin<SUI>,
    sui_min: u64,
    token: Coin<T>,
    token_min: u64,
    ctx: &mut TxContext
  ): Coin<LP<T>> {
    assert!(
      coin::value(&sui) >= sui_min && sui_min > 0,
      ERR_INSUFFICIENT_SUI
    );
    assert!(
      coin::value(&token) >= token_min && token_min > 0,
      ERR_INSUFFICIENT_TOKEN
    );

    let sui_balance = coin::into_balance(sui);
    let token_balance = coin::into_balance(token);

    let (sui_reserve, token_reserve, _lp_supply) = get_amounts(pool);

    let sui_added = balance::value(&sui_balance);
    let token_added = balance::value(&token_balance);

    let (optimal_sui, optimal_token) = calc_optimal_coin_values(
      sui_added,
      token_added,
      sui_min,
      token_min,
      sui_reserve,
      token_reserve
    );

    let share_minted = optimal_sui * optimal_token;

    if (optimal_sui < sui_added) {
      transfer::transfer(
        coin::from_balance(balance::split(&mut sui_balance, sui_added - optimal_sui), ctx),
        tx_context::sender(ctx)
      )
    };
    if (optimal_token < token_added) {
      transfer::transfer(
        coin::from_balance(balance::split(&mut token_balance, token_added - optimal_token), ctx),
        tx_context::sender(ctx)
      )
    };

    let sui_amount = balance::join(&mut pool.sui, sui_balance);
    let token_amount = balance::join(&mut pool.token, token_balance);

    assert!(sui_amount < MAX_POOL_VALUE, ERR_POOL_FULL);
    assert!(token_amount < MAX_POOL_VALUE, ERR_POOL_FULL);

    let balance = balance::increase_supply(&mut pool.lp_supply, share_minted);
    coin::from_balance(balance, ctx)
  }

  /// Remove liquidity from the `Pool` by burning `Coin<LP>`.
  /// Returns `Coin<T>` and `Coin<SUI>`.
  public fun remove_liquidity<T>(
    pool: &mut Pool<T>,
    lp: Coin<LP<T>>,
    ctx: &mut TxContext
  ): (Coin<SUI>, Coin<T>) {
    let lp_amount = coin::value(&lp);

    // If there's a non-empty LP, we can
    assert!(lp_amount > 0, ERR_ZERO_AMOUNT);

    let (sui_amount, token_amount, lp_supply) = get_amounts(pool);
    let sui_removed = mul_div(sui_amount, lp_amount, lp_supply);
    let token_removed = mul_div(token_amount, lp_amount, lp_supply);

    balance::decrease_supply(&mut pool.lp_supply, coin::into_balance(lp));

    (
      coin::take(&mut pool.sui, sui_removed, ctx),
      coin::take(&mut pool.token, token_removed, ctx)
    )
  }

  /// Swap `Coin<SUI>` for the `Coin<T>`.
  /// Returns Coin<T>.
  public fun swap_sui<T>(
    pool: &mut Pool<T>,
    sui: Coin<SUI>,
    token_min: u64,
    ctx: &mut TxContext
  ): Coin<T> {
    assert!(coin::value(&sui) > 0, ERR_ZERO_AMOUNT);

    let sui_balance = coin::into_balance(sui);

    // Calculate the output amount - fee
    let (sui_reserve, token_reserve, _) = get_amounts(pool);

    assert!(sui_reserve > 0 && token_reserve > 0, ERR_RESERVES_EMPTY);

    let token_amount = get_amount_out(
      balance::value(&sui_balance),
      sui_reserve,
      token_reserve,
    );

    assert!(
      token_amount >= token_min,
      ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
    );

    balance::join(&mut pool.sui, sui_balance);
    coin::take(&mut pool.token, token_amount, ctx)
  }

  /// Swap `Coin<T>` for the `Coin<SUI>`.
  /// Returns the swapped `Coin<SUI>`.
  public fun swap_token<T>(
    pool: &mut Pool<T>,
    token: Coin<T>,
    sui_min: u64,
    ctx: &mut TxContext
  ): Coin<SUI> {
    assert!(coin::value(&token) > 0, ERR_ZERO_AMOUNT);

    let token_balance = coin::into_balance(token);
    let (sui_reserve, token_reserve, _) = get_amounts(pool);

    assert!(sui_reserve > 0 && token_reserve > 0, ERR_RESERVES_EMPTY);

    let sui_amount = get_amount_out(
      balance::value(&token_balance),
      token_reserve,
      sui_reserve,
    );

    assert!(
      sui_amount >= sui_min,
      ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
    );

    balance::join(&mut pool.token, token_balance);
    coin::take(&mut pool.sui, sui_amount, ctx)
  }

  /// Calculate amounts needed for adding new liquidity for both `Sui` and `Token`.
  /// Returns both `Sui` and `Token` coins amounts.
  public fun calc_optimal_coin_values(
    sui_desired: u64,
    token_desired: u64,
    sui_min: u64,
    token_min: u64,
    sui_reserve: u64,
    token_reserve: u64
  ): (u64, u64) {
    if (sui_reserve == 0 && token_reserve == 0) {
      return (sui_desired, token_desired)
    } else {
      let token_returned = mul_div(sui_desired, token_reserve, sui_reserve);
      if (token_returned <= token_desired) {
        assert!(token_returned >= token_min, ERR_INSUFFICIENT_TOKEN);
        return (sui_desired, token_returned)
      } else {
        let sui_returned = mul_div(token_desired, token_reserve, sui_reserve);
        assert!(sui_returned <= sui_desired, ERR_OVERLIMIT_SUI);
        assert!(sui_returned >= sui_min, ERR_INSUFFICIENT_SUI);
        return (sui_returned, token_desired)
      }
    }
  }

  /// Implements: `x` * `y` / `z`.
  public fun mul_div(x: u64, y: u64, z: u64): u64 {
    assert!(z != 0, ERR_DIVIDE_BY_ZERO);
    let r = (x as u128) * (y as u128) / (z as u128);
    (r as u64)
  }

  /// Public getter for the price of SUI or Token T.
  /// - How much SUI one will get if they send `to_sell` amount of T;
  /// - How much T one will get if they send `to_sell` amount of SUI;
  public fun price<T>(pool: &Pool<T>, to_sell: u64): u64 {
    let (sui_amount, token_amount, _) = get_amounts(pool);
    get_amount_out(to_sell, token_amount, sui_amount)
  }

  /// Get most used values in a handy way:
  /// - amount of Sui
  /// - amount of Token
  /// - total supply of LP
  public fun get_amounts<T>(pool: &Pool<T>): (u64, u64, u64) {
    (
      balance::value(&pool.sui),
      balance::value(&pool.token),
      balance::supply_value(&pool.lp_supply)
    )
  }

  /// Calculate the output amount minus the fee - 0.3%
  public fun get_amount_out(
    coin_in: u64,
    reserve_in: u64,
    reserve_out: u64,
  ): u64 {
    let fee_multiplier = FEE_SCALE - FEE_MULTIPLIER;

    let coin_in_val_after_fees = coin_in * fee_multiplier;
    // reserve_in size after adding coin_in (scaled to 1000)
    let new_reserve_in = (reserve_in * FEE_SCALE) + coin_in_val_after_fees;

    // Multiply coin_in by the current exchange rate:
    // current_exchange_rate = reserve_out / reserve_in
    // amount_in_after_fees * current_exchange_rate -> amount_out
    mul_div(coin_in_val_after_fees, // scaled to 1000
      reserve_out,
      new_reserve_in  // scaled to 1000
    )
  }

  #[test_only]
  public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
  }
}

#[test_only]
/// Tests for the pool module.
/// They are sequential and based on top of each other.
/// ```
/// * - test_init_pool
/// |   +-- test_creation
/// |       +-- test_swap_sui
/// |           +-- test_swap_tok
/// |               +-- test_withdraw_almost_all
/// |               +-- test_withdraw_all
/// ```
module swap::pool_tests {
  use sui::sui::SUI;
  use sui::coin::{mint_for_testing as mint, destroy_for_testing as burn};
  use sui::test_scenario::{Self, Scenario, next_tx, ctx};
  use swap::implements::{Self, Pool, LP, Global};

  /// Gonna be our test token.
  struct BEEP {}

  const SUI_AMOUNT: u64 = 1000000000;
  const BEEP_AMOUNT: u64 = 1000000;

  // Tests section
  #[test] fun test_init_pool() { test_init_pool_(&mut scenario()) }
  #[test] fun test_add_liquidity() { test_add_liquidity_(&mut scenario()) }
  #[test] fun test_swap_sui() { test_swap_sui_(&mut scenario()) }
  #[test] fun test_swap_token() { test_swap_token_(&mut scenario()) }
  #[test] fun test_withdraw_almost_all() { test_withdraw_almost_all_(&mut scenario()) }
  #[test] fun test_withdraw_all() { test_withdraw_all_(&mut scenario()) }

  // Non-sequential tests
  #[test] fun test_math() { test_math_(&mut scenario()) }

  /// Init a Pool with a 1_000_000 BEEP and 1_000_000_000 SUI;
  /// Set the ratio BEEP : SUI = 1 : 1000.
  /// Set LP token amount to 1000;
  fun test_init_pool_(test: &mut Scenario) {
    let (owner, _) = people();

    next_tx(test, &owner); {
      implements::init_for_testing(ctx(test));
    };

    next_tx(test, &owner); {
      let global = test_scenario::take_shared<Global>(test);
      let global_mut = test_scenario::borrow_mut(&mut global);

      let lp = implements::create_pool(
        global_mut,
        mint<BEEP>(BEEP_AMOUNT, ctx(test)),
        mint<SUI>(SUI_AMOUNT, ctx(test)),
        ctx(test)
      );

      let burn = burn(lp);
      assert!(burn == 1000000000000000, burn);

      test_scenario::return_shared(test, global)
    };

    next_tx(test, &owner); {
      let pool = test_scenario::take_shared<Pool<BEEP>>(test);
      let pool_mut = test_scenario::borrow_mut(&mut pool);
      let (sui_amount, token_amount, lp_supply) = implements::get_amounts(pool_mut);

      assert!(lp_supply == 1000000000000000, lp_supply);
      assert!(sui_amount == SUI_AMOUNT, 0);
      assert!(token_amount == BEEP_AMOUNT, 0);

      test_scenario::return_shared(test, pool)
    };
  }

  /// Expect LP tokens to double in supply when the same values passed
  fun test_add_liquidity_(test: &mut Scenario) {
    test_init_pool_(test);

    let (_, theguy) = people();

    next_tx(test, &theguy); {
      let pool = test_scenario::take_shared<Pool<BEEP>>(test);
      let pool_mut = test_scenario::borrow_mut(&mut pool);
      let (sui_amount, token_amount, lp_supply) = implements::get_amounts(pool_mut);

      let lp_tokens = implements::add_liquidity(
        pool_mut,
        mint<SUI>(sui_amount, ctx(test)),
        1,
        mint<BEEP>(token_amount, ctx(test)),
        1,
        ctx(test)
      );

      let burn = burn(lp_tokens);
      assert!(burn == lp_supply, burn);

      test_scenario::return_shared(test, pool)
    };
  }

  /// The other guy tries to exchange 5_000_000 sui for ~ 5000 BEEP,
  /// minus the commission that is paid to the pool.
  fun test_swap_sui_(test: &mut Scenario) {
    test_init_pool_(test);

    let (_, the_guy) = people();

    next_tx(test, &the_guy); {
      let pool = test_scenario::take_shared<Pool<BEEP>>(test);
      let pool_mut = test_scenario::borrow_mut(&mut pool);

      let token = implements::swap_sui(
        pool_mut,
        mint<SUI>(5000000, ctx(test)),
        0,
        ctx(test)
      );

      // Check the value of the coin received by the guy.
      // Due to rounding problem the value is not precise
      // (works better on larger numbers).
      assert!(burn(token) > 4950, 1);

      test_scenario::return_shared(test, pool);
    };
  }

  /// The owner swaps back BEEP for SUI and expects an increase in price.
  /// The sent amount of BEEP is 1000, initial price was 1 BEEP : 1000 SUI;
  fun test_swap_token_(test: &mut Scenario) {
    test_swap_sui_(test);

    let (owner, _) = people();

    next_tx(test, &owner); {
      let pool = test_scenario::take_shared<Pool<BEEP>>(test);
      let pool_mut = test_scenario::borrow_mut(&mut pool);

      let sui = implements::swap_token(
        pool_mut,
        mint<BEEP>(1000, ctx(test)),
        0,
        ctx(test)
      );

      // Actual win is 1005971, which is ~ 0.6% profit
      assert!(burn(sui) > 1000000u64, 2);

      test_scenario::return_shared(test, pool);
    };
  }

  /// Withdraw (MAX_LIQUIDITY - 1) from the pool
  fun test_withdraw_almost_all_(test: &mut Scenario) {
    test_swap_token_(test);

    let (owner, _) = people();

    // someone tries to pass MINTED_LSP and hopes there will be just 1 BEEP
    next_tx(test, &owner); {
      let lp = mint<LP<BEEP>>(1000000000000000-1, ctx(test));
      let pool = test_scenario::take_shared<Pool<BEEP>>(test);
      let pool_mut = test_scenario::borrow_mut(&mut pool);

      let (sui, token) = implements::remove_liquidity(pool_mut, lp, ctx(test));
      let (sui_reserve, token_reserve, lp_supply) = implements::get_amounts(pool_mut);

      assert!(lp_supply == 1, 3);
      assert!(token_reserve > 0, 3); // actually 1 BEEP is left
      assert!(sui_reserve > 0, 3);

      burn(sui);
      burn(token);

      test_scenario::return_shared(test, pool);
    }
  }

  /// The owner tries to withdraw all liquidity from the pool.
  fun test_withdraw_all_(test: &mut Scenario) {
    test_swap_token_(test);

    let (owner, _) = people();

    next_tx(test, &owner); {
      let lp = mint<LP<BEEP>>(1000000000000000, ctx(test));
      let pool = test_scenario::take_shared<Pool<BEEP>>(test);
      let pool_mut = test_scenario::borrow_mut(&mut pool);

      let (sui, token) = implements::remove_liquidity(pool_mut, lp, ctx(test));
      let (sui_reserve, token_reserve, lp_supply) = implements::get_amounts(pool_mut);

      assert!(sui_reserve == 0, 3);
      assert!(token_reserve == 0, 3);
      assert!(lp_supply == 0, 3);

      // make sure that withdrawn assets
      let burn_sui = burn(sui);
      let burn_token = burn(token);
      assert!(burn_sui == 1003994029, burn_sui);
      assert!(burn_token == 996040, burn_token);

      test_scenario::return_shared(test, pool);
    };
  }

  /// This just tests the math.
  fun test_math_(_: &mut Scenario) {
    let u64_max = 18446744073709551615;
    let max_val = u64_max / 10000 - 10000;

    // Try small values
    assert!(implements::get_amount_out(10, 1000, 1000) == 9, implements::get_amount_out(10, 1000, 1000));

    // Even with 0 comission there's this small loss of 1
    assert!(implements::get_amount_out(10000, max_val , max_val) == 9969, implements::get_amount_out(10000, max_val, max_val));
    assert!(implements::get_amount_out(1000, max_val, max_val) == 996, implements::get_amount_out(1000, max_val, max_val));
    assert!(implements::get_amount_out(100, max_val, max_val) == 99, implements::get_amount_out(100, max_val, max_val));
  }

  // utilities
  fun scenario(): Scenario { test_scenario::begin(&@0x1) }
  fun people(): (address, address) { (@0xBEEF, @0x1337) }
}