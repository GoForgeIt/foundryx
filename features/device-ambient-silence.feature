Feature: Device and liveness transitions speak only when authorized

  The two PLAN-LEVEL scenarios of track 20260725T2306_device_agnostic_recording_source
  (ledger rows P01 and P02). They are not in the frozen spec; they carry the two
  carry-forward findings the plan admits by allow-list, and the T0 Then-capability
  verifier parses their Then clauses from THIS file.

  Authoring note (T0): the scenario TEXT is authored here because the T0 verifier
  (`ThenCapabilityMapTests`) must read it, and a verifier that silently skips an absent
  file would be exactly the kind of unfailable check this track forbids. The STEP
  DEFINITIONS and the production seams they drive belong to T8; until T8 lands, no test
  runs this feature and the file is a declaration only.

  Scenario: in-flight user capture stays silent across device/liveness transition and source switch
    Given a live user-started capture is open
    And no registered playbook matches and nobody has mentioned an agent
    When the active device changes liveness and the capture source switches
    Then no alert is posted
    And no Live Activity is created
    And the existing capture identity remains
    And the source switch is status-only unless a registered playbook or explicit mention authorizes action

  Scenario: surface-open device transition does not create or alert any posting seam
    Given a device or status surface is open
    And no registered playbook matches and nobody has mentioned an agent
    When the active device transitions
    Then the agent-dispatch seam receives zero actions
    And the notification posting seam receives zero create, update, or alert posts on account of that device or liveness transition
    And the live-activity posting seam receives zero create, update, or alert posts on account of that device or liveness transition
    And the widget posting seam receives zero create, update, or alert posts on account of that device or liveness transition
