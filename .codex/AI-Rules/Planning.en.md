# Planning Rules

A plan's detail should be proportionate to the change's scope, risk, and uncertainty. Include only information that helps implementation or acceptance; do not fill irrelevant fields merely because a template contains them.

- For a low-risk, well-understood change within one area, use a concise plan containing only the objective, change, validation, and known risks or Scope boundaries.
- For changes that cross multiple areas, involve data migration, security, public contracts, or otherwise carry high risk, use the full format below and repeat change items and test scenarios as needed.
- When test-first development applies, describe the TDD Red-Green-Refactor sequence. When a Testing Rules exemption applies, record the reason and alternative validation method.

Concise plan format:

```markdown
- Objective:
- Change:
- Validation:
- Risks / out of scope:
```

Full plan format:

```markdown
# Plan: <Feature or problem name>

## 1. Objective and Scope
- Overall expected result:
- Expected deliverables: <Summary of verifiable deliverables upon completion>
- Out of scope: <Reason for exclusion or follow-up; enter "None" when there are no exclusions>

## 2. Proposed Changes

### 2.1 <Change name>
- Change:
- Reason:
- Impact or risk:

## 3. Test Scenarios

### 3.1 <Test scenario name>
- Related change item:
- Test level:
- Given:
- When:
- Then:
- TDD: Red <test that fails first> → Green <smallest production code change> → Refactor <cleanup that keeps tests passing>; when not applicable, state the reason and alternative validation method.
```
