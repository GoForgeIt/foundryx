Feature: FoundryX chat makes agentic work legible

  The phone chat is not plain chat — every turn runs Kiln's full agentic loop
  (Mode-B) with a permissive tool catalog (read/write/edit/search + bash + MCP),
  gated by an ask-first approval policy. Kiln owns those harness decisions; this
  surface only makes them VISIBLE. The chat surfaces a quiet affordance that the
  assistant can act, renders each streamed tool event as an inline row as it
  happens (expandable to its result), shows a live status line, and — when the
  agent asks to run something — shows the concrete command (or file + diff)
  before the user approves. Driven against the REAL ChatViewModel folding REAL
  DoorEvents parsed from the REAL kiln-session SSE wire shape — no mocks.

  Scenario: the user can tell chat is agentic
    Given I open a new chat
    Then I see a clear signal that the assistant can read/write files and run commands

  Scenario: tool activity is visible inline as it happens
    Given a turn is in flight
    When the assistant reads a file and runs a command
    Then I see one inline activity row per tool action
    And each row names the tool and its primary argument

  Scenario: a tool row shows its result once the tool completes
    Given the assistant ran a command in the current turn
    When the tool result arrives
    Then the row for that command is no longer running
    And the row carries the command's output for expansion

  Scenario: the live status line reflects what the agent is doing
    Given a turn is in flight
    When the assistant is running a command
    Then the status line reads that it is running that tool
    And when the turn completes the status line reports the number of steps

  Scenario: approval shows exactly what will run
    Given the assistant wants to run a shell command
    When the approval prompt appears
    Then it shows the exact command before I approve
    And the turn stays suspended until I answer

  Scenario: approval for a file edit shows the file and its change
    Given the assistant wants to edit a file
    When the approval prompt appears
    Then it shows the file path and the before/after text of the edit
