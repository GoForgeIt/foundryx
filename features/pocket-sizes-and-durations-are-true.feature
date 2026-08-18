Feature: A recorder's sizes and lengths are true, or they are absent

  On 2026-08-18 two files came off Nick's own recorder — the first ever, in this program's life.
  The recorder's listing had called them 4 and 46. They were 19,770 and 185,078 bytes.

  Read as bytes the listing is out by 4,943x and then by 4,023x. Read as kibibytes the real file
  is 4.83x and then 3.93x larger. A unit that is wrong by a VARYING factor is not a unit, and
  both readings have shipped: this app once printed "44 min" on every row by dividing the listing
  by an unmeasured 4,000 bytes/second, and then printed "4 KB" for the 19,770-byte recording by
  calling the same number kilobytes. Twice now, the fix for an invented magnitude has been a
  different invented magnitude.

  So these scenarios do not assert a spelling. They assert the PROPERTY: nothing a person can see
  changes when the listing number changes. A surface that obeys that cannot print a magnitude
  derived from it, in any unit, under any rounding, in any sentence somebody adds later.

  And the other half is real now. The files decode as 32 kbps CBR — 4,000 bytes per second,
  measured off the frame header — so a recording whose true byte count is known CAN say how long
  it runs. What it takes is a byte count somebody measured: the one a recorder announces when it
  starts sending, or the length of the file this phone is already holding.

  Scenario: Nothing on a row changes when the recorder's listing number changes
    Given recorders listing one recording with wildly different listing numbers
    When I look at the row each of them draws
    Then every row reads exactly the same, whatever the recorder listed
    And no row states a magnitude at all
    And there is a row, so this is not a claim about an empty page

  Scenario: Nothing on the page about one recording changes when the listing number changes
    Given recorders listing one recording with wildly different listing numbers
    When I open the page about that recording on each of them
    Then every page reads exactly the same, whatever the recorder listed
    And no page refuses to bring a recording over because of a size nobody measured

  Scenario: A recording whose real byte count is known says how long it runs
    Given the two recordings that actually came off the recorder
    Then each row states the length its measured bytes imply
    And the page about it states that length too, and stops saying nobody knows

  Scenario: The recorder says how full it is, and states no amount nobody can defend
    Given the recorder's own answer about its storage
    Then the line says how full it is
    And it states no amount in bytes, kilobytes, megabytes or gigabytes
    And the same fullness counted in another unit reads exactly the same
