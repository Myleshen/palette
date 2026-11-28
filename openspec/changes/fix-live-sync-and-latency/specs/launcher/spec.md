## ADDED Requirements

### Requirement: Provider first response

A bound provider that shells out SHALL not make the user wait for a status probe
that could have been made in the background, and independent remote queries for
one provider SHALL run concurrently.

#### Scenario: First Bitwarden search after launch

- **WHEN** the user opens `/bw` shortly after launch
- **THEN** the vault status was already probed in the background and the row
  renders without a new CLI round trip

#### Scenario: GitHub list

- **WHEN** `/gh` fetches pull requests and issues for the first time
- **THEN** both queries are in flight at once rather than sequentially
