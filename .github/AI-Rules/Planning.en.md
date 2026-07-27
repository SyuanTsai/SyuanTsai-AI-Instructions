# Planning Rules

A plan should clearly connect the overall objective, expected deliverables, proposed changes, test scenarios, and Scope boundaries so that the overall outcome and each change's objective, content, reason, and verification method are traceable. When test-first development applies, describe each test scenario using the TDD Red-Green-Refactor sequence. When a change meets an exemption in the Testing Rules, clearly record the reason and alternative verification method. Add or remove numbered items as appropriate for the task, and use this format:

```markdown
# Plan: <Feature or problem name>

## 1. Objective
- Overall expected result:
- Expected deliverables: <Summary of verifiable deliverables upon completion>

## 2. Proposed Changes

### 2.1 <Change name>
- Item objective:
- Change:
- Reason:

### 2.2 <Change name>
- Item objective:
- Change:
- Reason:

## 3. Test Scenarios

### 3.1 <Test scenario name>
- Related change item:
- TDD mode: Red-Green-Refactor / Not applicable (reason and alternative verification method)
- Given:
- When:
- Then:
- Red: The test to add or update first, which is expected to fail because the target behavior is not yet implemented.
- Green: The smallest expected production code change that makes the test pass.
- Refactor: The cleanup expected after the test passes while keeping the test passing.

### 3.2 <Test scenario name>
- Related change item:
- TDD mode: Red-Green-Refactor / Not applicable (reason and alternative verification method)
- Given:
- When:
- Then:
- Red: The test to add or update first, which is expected to fail because the target behavior is not yet implemented.
- Green: The smallest expected production code change that makes the test pass.
- Refactor: The cleanup expected after the test passes while keeping the test passing.

## 4. Out of Scope
- <Excluded item>: <Reason for exclusion or expected follow-up; enter "None" when there are no excluded items>
```
