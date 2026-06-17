import Verso
import VersoManual
import VersoBlueprint
import Mathlib

open Verso.Genre
open Verso.Genre.Manual
open Informal
open scoped BigOperators

#doc (Manual) "Domino Puzzle Proof" =>

:::group "introduction"
The Answer
:::

:::theorem "domino_impossible" (parent := "introduction")
No, it is not possible to cover a $`10 \times 10` board with an equal number of horizontal and vertical $`2 \times 1` tiles.

```md "domino_impossible" (slot := statement)
No, it is not possible to cover a $10 \times 10$ board with an equal number of horizontal and vertical $2 \times 1$ tiles.
```
:::

:::proof "domino_impossible"
Here is the rigorous mathematical proof using set theory, a coloring function, and a parity argument.

```md "domino_impossible" (slot := proof)
Here is the rigorous mathematical proof using set theory, a coloring function, and a parity argument.
```
:::

```lean "domino_impossible"
theorem domino_impossible : False := by
  sorry
```

:::group "formal_definitions"
Formal Definitions
:::

:::definition "board_def" (parent := "formal_definitions")
Let the board be defined as a set of discrete coordinates:

$$`B = \{(x,y) \in \mathbb{Z}^2 \mid 1 \le x \le 10, 1 \le y \le 10\}`

```md "board_def"
Let the board be defined as a set of discrete coordinates:

$$B = \{(x,y) \in \mathbb{Z}^2 \mid 1 \le x \le 10, 1 \le y \le 10\}$$
```
:::

```lean "board_def"
def Board : Finset (Int × Int) := sorry
```

:::definition "valid_tiling_def" (parent := "formal_definitions")
Let a valid tiling of the {uses "board_def"}[board] be a partition of $`B` into a set of horizontal dominoes $`H` and a set of vertical dominoes $`V`, where each domino consists of exactly two adjacent coordinates.

```md "valid_tiling_def"
Let a valid tiling of the board be a partition of $B$ into a set of horizontal dominoes $H$ and a set of vertical dominoes $V$, where each domino consists of exactly two adjacent coordinates.
```
:::

```lean "valid_tiling_def"
def ValidTiling (H V : Finset (Finset (Int × Int))) : Prop := sorry
```

:::lemma_ "total_dominoes_lemma" (parent := "formal_definitions")
Since $`|B| = 100` and each domino in {uses "valid_tiling_def"}[a valid tiling] covers $`2` squares, the total number of dominoes is:

$$`|H| + |V| = 50`

```md "total_dominoes_lemma"
Since $|B| = 100$ and each domino covers $2$ squares, the total number of dominoes is:

$$|H| + |V| = 50$$
```
:::

```lean "total_dominoes_lemma"
lemma total_dominoes (H V : Finset (Finset (Int × Int))) (h : ValidTiling H V) : H.card + V.card = 50 := by sorry
```

:::lemma_ "equal_dominoes_lemma" (parent := "formal_definitions")
The puzzle requires the number of horizontal and vertical dominoes to be equal. Therefore, $`|H| = |V|`, which implies:

$$`|H| = 25 \quad \text{and} \quad |V| = 25`

```md "equal_dominoes_lemma"
The puzzle requires the number of horizontal and vertical dominoes to be equal. Therefore, $|H| = |V|$, which implies:

$$|H| = 25 \quad \text{and} \quad |V| = 25$$
```
:::

```lean "equal_dominoes_lemma"
lemma equal_dominoes (H V : Finset (Finset (Int × Int))) (h : ValidTiling H V) (heq : H.card = V.card) : H.card = 25 ∧ V.card = 25 := by sorry
```

:::group "coloring_function"
The Coloring Function
:::

:::definition "coloring_def" (parent := "coloring_function")
Define a coloring (or weight) function $`c: B \to \{0, 1\}` that maps each square to either $`0` or $`1` based strictly on its column (x-coordinate):

$$`c(x,y) = x \pmod 2`

```md "coloring_def"
Define a coloring (or weight) function $c: B \to \{0, 1\}$ that maps each square to either $0$ or $1$ based strictly on its column (x-coordinate):

$$c(x,y) = x \pmod 2$$
```
:::

```lean "coloring_def"
def coloring (p : Int × Int) : Int := p.1 % 2
```

:::lemma_ "board_weight_lemma" (parent := "coloring_function")
The total sum of the {uses "coloring_def"}[coloring function] over the entire {uses "board_def"}[board] $`B` is the sum of $`5` columns of $`1`s and $`5` columns of $`0`s, each with $`10` squares:

$$`S(B) = \sum_{(x,y) \in B} c(x,y) = 50(1) + 50(0) = 50`

```md "board_weight_lemma"
The total sum of the coloring function over the entire board $B$ is the sum of $5$ columns of $1$s and $5$ columns of $0$s, each with $10$ squares:

$$S(B) = \sum_{(x,y) \in B} c(x,y) = 50(1) + 50(0) = 50$$
```
:::

```lean "board_weight_lemma"
lemma board_weight : ∑ p ∈ Board, coloring p = 50 := by sorry
```

:::group "tile_weights"
Tile Weights
:::

We now evaluate the sum of the coloring function for individual horizontal and vertical tiles:

:::lemma_ "horizontal_weight_lemma" (parent := "tile_weights")
Horizontal Dominoes ($`h \in H`): A horizontal tile spans two adjacent columns, taking the form $`\{(x,y), (x+1, y)\}`. Its weight is:

$$`S(h) = (x \pmod 2) + ((x+1) \pmod 2) = 1`

Every horizontal domino has a weight of exactly $`1`.

```md "horizontal_weight_lemma"
Horizontal Dominoes ($h \in H$): A horizontal tile spans two adjacent columns, taking the form $\{(x,y), (x+1, y)\}$. Its weight is:

$$S(h) = (x \pmod 2) + ((x+1) \pmod 2) = 1$$

Every horizontal domino has a weight of exactly $1$.
```
:::

```lean "horizontal_weight_lemma"
lemma horizontal_weight (H : Finset (Finset (Int × Int))) (h : Finset (Int × Int)) (hin : h ∈ H) : ∑ p ∈ h, coloring p = 1 := by sorry
```

:::lemma_ "vertical_weight_lemma" (parent := "tile_weights")
Vertical Dominoes ($`v \in V`): A vertical tile stays within a single column, taking the form $`\{(x,y), (x, y+1)\}`. Its weight is:

$$`S(v) = (x \pmod 2) + (x \pmod 2) = 2(x \pmod 2)`

Therefore, $`S(v) \in \{0, 2\}`. Regardless of its placement, every vertical domino has an even weight.

```md "vertical_weight_lemma"
Vertical Dominoes ($v \in V$): A vertical tile stays within a single column, taking the form $\{(x,y), (x, y+1)\}$. Its weight is:

$$S(v) = (x \pmod 2) + (x \pmod 2) = 2(x \pmod 2)$$

Therefore, $S(v) \in \{0, 2\}$. Regardless of its placement, every vertical domino has an even weight.
```
:::

```lean "vertical_weight_lemma"
lemma vertical_weight (V : Finset (Finset (Int × Int))) (v : Finset (Int × Int)) (vin : v ∈ V) : ∃ k : Int, ∑ p ∈ v, coloring p = 2 * k := by sorry
```

:::group "parity_contradiction"
Parity Contradiction
:::

:::lemma_ "parity_contradiction_lemma" (parent := "parity_contradiction")
Since the tiles partition the board, the total weight of the board $`S(B)` must equal the sum of the weights of all individual tiles:

$$`S(B) = \sum_{h \in H} S(h) + \sum_{v \in V} S(v)`

Substitute the known values into the equation (using {uses "horizontal_weight_lemma"}[] and {uses "vertical_weight_lemma"}[]):

$$`50 = \sum_{h \in H} 1 + \sum_{v \in V} 2(x_v \pmod 2)`

Because $`|H| = 25` (from {uses "equal_dominoes_lemma"}[]), the sum for the horizontal dominoes is exactly $`25`:

$$`50 = 25 + 2 \sum_{v \in V} (x_v \pmod 2)`

Subtracting $`25` from both sides yields:

$$`25 = 2 \sum_{v \in V} (x_v \pmod 2)`

Let $`k = \sum_{v \in V} (x_v \pmod 2)`. Since $`k` is an integer, the equation simplifies to:

$$`25 = 2k`

This equation asserts that an odd integer ($`25`) is equal to an even integer ($`2k`). This is a fundamental contradiction with {uses "board_weight_lemma"}[]. Therefore, no such tiling exists. $`\blacksquare`

```md "parity_contradiction_lemma"
Since the tiles partition the board, the total weight of the board $S(B)$ must equal the sum of the weights of all individual tiles:

$$S(B) = \sum_{h \in H} S(h) + \sum_{v \in V} S(v)$$

Substitute the known values into the equation:

$$50 = \sum_{h \in H} 1 + \sum_{v \in V} 2(x_v \pmod 2)$$

Because $|H| = 25$, the sum for the horizontal dominoes is exactly $25$:

$$50 = 25 + 2 \sum_{v \in V} (x_v \pmod 2)$$

Subtracting $25$ from both sides yields:

$$25 = 2 \sum_{v \in V} (x_v \pmod 2)$$

Let $k = \sum_{v \in V} (x_v \pmod 2)$. Since $k$ is an integer, the equation simplifies to:

$$25 = 2k$$

This equation asserts that an odd integer ($25$) is equal to an even integer ($2k$). This is a fundamental contradiction. Therefore, no such tiling exists. $\blacksquare$
```
:::

```lean "parity_contradiction_lemma"
lemma parity_contradiction : False := by sorry
```
