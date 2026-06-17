The Answer

No, it is not possible to cover a $10 \times 10$ board with an equal number of horizontal and vertical $2 \times 1$ tiles.

Here is the rigorous mathematical proof using set theory, a coloring function, and a parity argument.

1. Formal Definitions

Let the board be defined as a set of discrete coordinates:

$$B = \{(x,y) \in \mathbb{Z}^2 \mid 1 \le x \le 10, 1 \le y \le 10\}$$

Let a valid tiling of the board be a partition of $B$ into a set of horizontal dominoes $H$ and a set of vertical dominoes $V$, where each domino consists of exactly two adjacent coordinates.

Since $|B| = 100$ and each domino covers $2$ squares, the total number of dominoes is:

$$|H| + |V| = 50$$

The puzzle requires the number of horizontal and vertical dominoes to be equal. Therefore, $|H| = |V|$, which implies:

$$|H| = 25 \quad \text{and} \quad |V| = 25$$

2. The Coloring Function

Define a coloring (or weight) function $c: B \to \{0, 1\}$ that maps each square to either $0$ or $1$ based strictly on its column (x-coordinate):

$$c(x,y) = x \pmod 2$$

The total sum of the coloring function over the entire board $B$ is the sum of $5$ columns of $1$s and $5$ columns of $0$s, each with $10$ squares:

$$S(B) = \sum_{(x,y) \in B} c(x,y) = 50(1) + 50(0) = 50$$

3. Tile Weights

We now evaluate the sum of the coloring function for individual horizontal and vertical tiles:

Horizontal Dominoes ($h \in H$): A horizontal tile spans two adjacent columns, taking the form $\{(x,y), (x+1, y)\}$. Its weight is:

$$S(h) = (x \pmod 2) + ((x+1) \pmod 2) = 1$$

Every horizontal domino has a weight of exactly $1$.

Vertical Dominoes ($v \in V$): A vertical tile stays within a single column, taking the form $\{(x,y), (x, y+1)\}$. Its weight is:

$$S(v) = (x \pmod 2) + (x \pmod 2) = 2(x \pmod 2)$$

Therefore, $S(v) \in \{0, 2\}$. Regardless of its placement, every vertical domino has an even weight.

4. Parity Contradiction

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