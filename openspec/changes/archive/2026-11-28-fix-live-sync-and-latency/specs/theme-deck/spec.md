## ADDED Requirements

### Requirement: Wallpaper thumbnail warm-up

The deck SHALL decode wallpaper thumbnails concurrently, bounded so the app
stays responsive, and SHALL have every visible card's picture ready within one
second on a cold cache for a local wallpaper folder of 4K–8K images.

#### Scenario: Cold open

- **WHEN** the wallpaper deck opens with an empty thumbnail cache and fifteen
  visible cards
- **THEN** all fifteen pictures are ready in under 1 s

#### Scenario: Cards before their picture

- **WHEN** a card's picture has not decoded yet
- **THEN** the card shows its extracted palette background, never an empty
  placeholder icon

#### Scenario: Warm open

- **WHEN** the cache already holds a card's downsample
- **THEN** the card reads the cache and does not decode the original file
