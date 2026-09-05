import { surchargeFor, pricedAt } from '../src/lib/surcharge.js'
import { test, assertEqual, assertThrows } from './helpers.js'

// --- which amount applies ---

test('an item with no override follows its section', () => {
  assertEqual(surchargeFor({ section: 1_000, item: null }), 1_000, 'Rs10 in the AC room')
})

test('a section charging nothing extra adds nothing', () => {
  assertEqual(surchargeFor({ section: 0, item: null }), 0)
})

test('an item override of zero is exempt, not unset', () => {
  // The distinction the nullable column exists for: tea stays Rs20 in the AC
  // room. A plain zero default could not say this, and raising the section
  // from Rs10 to Rs15 would silently skip every item.
  assertEqual(surchargeFor({ section: 1_000, item: 0 }), 0)
})

test('an item override replaces the section amount', () => {
  assertEqual(surchargeFor({ section: 1_000, item: 2_500 }), 2_500)
})

test('an item override applies even where the section charges nothing', () => {
  // Set deliberately on the item, so it is honoured in Non-AC too. Surprising
  // enough that it is the settings screen's job to make it visible, but the
  // rule stays simple: the item wins.
  assertEqual(surchargeFor({ section: 0, item: 1_000 }), 1_000)
})

test('a takeaway or delivery has no section, so no surcharge', () => {
  // There is no table and no room to air-condition. Charging for one would be
  // charging for something the customer never got.
  assertEqual(surchargeFor({ section: null, item: null }), 0)
  assertEqual(surchargeFor({ section: null, item: 2_500 }), 0, 'still nowhere to sit')
})

// --- the priced line ---

test('the surcharge is added to the unit price', () => {
  assertEqual(pricedAt(7_500, { section: 1_000, item: null }), 8_500, 'Rs75 soup at Rs85')
})

test('it is per item, not per order', () => {
  // Three soups at an AC table carry Rs30 of surcharge between them, because
  // each one is priced at Rs85. Adding it once per order would undercharge.
  const unit = pricedAt(7_500, { section: 1_000, item: null })
  assertEqual(unit * 3, 25_500)
})

test('nothing changes when no surcharge applies', () => {
  // The migration defaults every section to zero, so the day it ships no price
  // moves anywhere until someone sets one.
  assertEqual(pricedAt(7_500, { section: 0, item: null }), 7_500)
})

// --- the rules that produce wrong bills if broken ---

test('the result is integer paise', () => {
  const priced = pricedAt(7_500, { section: 1_000, item: null })
  assertEqual(Number.isInteger(priced), true)
})

test('a fractional surcharge is refused rather than rounded', () => {
  // Money is integer paise everywhere. A float arriving here would drift, and
  // silently flooring it would undercharge by a paisa a line.
  assertThrows(() => surchargeFor({ section: 1_000.5, item: null }))
  assertThrows(() => surchargeFor({ section: 1_000, item: 12.7 }))
})

test('a negative surcharge is refused', () => {
  // A discount dressed as a surcharge would skip the discount rules entirely —
  // it would not be recorded, and it could take a line below zero.
  assertThrows(() => surchargeFor({ section: -1_000, item: null }))
  assertThrows(() => surchargeFor({ section: 0, item: -1 }))
})

test('a priced line is never negative', () => {
  assertThrows(() => pricedAt(-100, { section: 0, item: null }))
})
