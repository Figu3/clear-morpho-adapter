# Vault Clear sur Morpho V2 : spécification

Statut : v0.3.1, 2026-10-30. Implémenté, testé sur fork mainnet, deux passes de revue IA (findings corrigés en §8), **pas d'audit externe, non déployé**.

Historique :
- v0.1 (commit `2b194922a`) : vault en USDC, un adapter vers la BaseReserve avec deux routes et le pool Uniswap dans l'adapter. Abandonnée.
- v0.2 (ce document) : **vault en BaseLP**, un `ClearMetaReserveAdapter` (BaseLP en entrée et en sortie) et un `ClearZap` en périphérie pour USDC/USDT ↔ parts du vault.

Sources lues :
- Clear V1 : `TreveeXYZ/clear-smart-contracts`, branche `v1.0-pashov-audit-fixes` (`b80f8be`, identique à `main` pour les contrats).
- Morpho : `morpho-org/vault-v2` (`0769889`), recopié dans `lib/morpho-vault-v2`.
- État on-chain lu le 2026-10-29.

---

## 1. Architecture

```
utilisateur ──USDC/USDT──▶ ClearZap ──BaseLP──▶ VaultV2 (asset = BaseLP) ──BaseLP──▶ ClearMetaReserveAdapter ──▶ MetaReserve USDS / PYUSD / USDG
            ◀─USDC/USDT── ClearZap ◀─BaseLP── VaultV2 ◀──BaseLP── ClearMetaReserveAdapter ◀──
```

- **Le vault ne connaît que le BaseLP.** Sa part BaseLP idle rapporte déjà le rendement de la BaseReserve, et la valorisation du vault n'a jamais besoin d'un prix USD.
- **L'adapter** place du BaseLP dans une MetaReserve (un adapter par MetaReserve) et le récupère, toujours par le chemin single-asset côté BaseLP.
- **Le zap** gère l'USDC et l'USDT. Il essaie d'abord le chemin single-asset de la BaseReserve, et sinon passe par la route équilibrée plus un swap de l'autre jambe : sur le pool Uniswap V3 USDC/USDT 1 bp par défaut, ou via une route KyberSwap fournie par l'appelant (`swapData`).

---

## 2. Ce que le code Clear V1 impose

| Fait (code et état on-chain) | Conséquence |
|---|---|
| BaseLP : ERC20 18 décimales, NAV au pair (`totalReserveValue`) **sans oracle**. Transfert standard, pas de frais. | Compatible avec les exigences de token de Morpho V2. Un vault à 18 décimales a un offset virtuel nul : il faut un dépôt d'amorçage. |
| MetaReserve : NAV au prix de rachat, **lit l'oracle et revert** `OraclePriceOutdated` dès qu'un prix dépasse 1 h (constaté on-chain). | `realAssets()` ne peut pas appeler `convertToValue` de la MetaReserve : il recalcule la position à partir de `netBalanceOf` (sans oracle), et seul le prix du natif passe par l'oracle, sous try/catch (§4). |
| Porte single-asset de la MetaReserve (`_requireLegsOnPeg`) : le natif à moins de 3 bps de son prix de rachat (0,9999 on-chain), **et** `baseReserve.assetsOnPeg(3 bps)`, donc l'USDT à moins de 3 bps de **0,9992**. | La contrainte USDT s'applique aussi à l'adapter. Sur 1 an de prix Binance 5 min (approximation de Pyth) : porte ouverte **~30 % du temps** au mieux (avant même la condition sur le natif), plus longue fermeture continue 48 jours. **L'adapter est immobilisé quand la porte est fermée** (§5.2). |
| Frais single-asset : 10 bps on-chain (BaseReserve et MetaReserves), plus un frais de spread qui couvre l'écart de ratio. | Aller-retour adapter ≈ 20 bps. Coût d'entrée et de sortie du zap single-asset ≈ 10 bps chacun. |
| Les dépôts et retraits équilibrés n'ont ni frais ni porte. Le dépôt équilibré crédite chaque actif à `min(market, redemption, 1 $)`. | Route de repli du zap. Quand l'USDT cote au-dessus de 0,9992, la jambe USDT est créditée à 0,9992 : une perte d'environ (prix − 0,9992) × poids USDT, comptée dans la borne de coût des tests. |
| MetaReserves on-chain : cible 70/30 BaseLP/natif, `prox` 3 bps, frais 10 bps, toutes vides au 29/10. | Les tests amorcent la MetaReserve USDS. |
| `setSingleAssetFeeBps` est sous le rôle Admin (Safe `0x5cB07DCe`), **délai d'exécution 0**. | Risque de gouvernance (§6). |

---

## 3. Contraintes Morpho V2 retenues

- **`realAssets()` ne doit jamais revert**, sinon `accrueInterest` et tout le vault sont bloqués. Seule exception retenue : pendant un appel Clear (verrou transitoire, §4), où le revert ne bloque que la transaction qui tient le verrou.
- Seul le vault appelle `allocate` / `deallocate`. Après `deallocate`, le vault fait `transferFrom(adapter, assets)`.
- `forceDeallocate` est ouvert à tous, avec une `data` arbitraire et une pénalité d'au plus 2 %.
- Les gains sont plafonnés par `maxRate`, les pertes réalisées tout de suite.

---

## 4. Valorisation de l'adapter, en BaseLP

```
s, S        = MetaLP de l'adapter, totalSupply MetaLP + 1 (part virtuelle)
baseUnits   = meta.netBalanceOf(BaseLP) · s / S          // sans oracle
nativeUnits = meta.netBalanceOf(natif)  · s / S          // sans oracle
nativeMark  = min(prix, rachat, 1 $) du natif            // oracle, sous try/catch
parPerShare = base.convertToValue(1e18)                  // sans oracle, borne haute du prix du BaseLP
realAssets  = (baseUnits + nativeUnits · nativeScale · nativeMark / parPerShare) · (1 − exitFeeBps) + BaseLP idle
```

- C'est la créance pro rata nette de dette IOU, la base sur laquelle la MetaReserve paie une sortie équilibrée. La valeur virtuelle est ignorée, ce qui ne fait que baisser le résultat.
- Le natif est converti à son prix prudent **divisé par la valeur au pair du BaseLP**, qui est une borne haute : la conversion ne surestime jamais.
- **Oracle muet** (périmé ou invalidé) : `staleNativeMark = dernierPrix × (1 − staleHaircutBps − staleDecayBpsPerDay × âge en jours)`, plancher 0. Le dernier prix est **toujours** celui que l'oracle garde en storage (lu via `oracleConfiguration`, qui ne vérifie pas la fraîcheur) et son âge part de son **heure de publication**, pour qu'un dépeg poussé après le dernier `poke` ne soit pas oublié et qu'un `poke` tardif ne remette pas l'âge à zéro (re-audit, finding 2 ; l'oracle Clear accepte une heure de publication antérieure au bloc). Si l'oracle ne garde aucun prix (`invalidatePrice`), on reprend `lastNativeMark` de l'adapter ; `lastMarkAt` stocke l'heure de publication du prix d'où il vient. Avec 50 bps + 100 bps/jour, la jambe native est à zéro après environ 99 jours. La baisse est réalisée tout de suite par le vault, la remontée revient au rythme de `maxRate` (audit, finding 3).
- `poke()` (sans permission) rafraîchit `lastNativeMark`. `allocate` et `deallocate` le rafraîchissent aussi.
- **Pendant un appel Clear** (`factory.globalLockHolder() != 0`, en particulier dans le callback d'un flash loan), `realAssets` **revert** `ClearCallInProgress`. Les deux reserves prêtent leurs soldes comptabilisés pendant ce callback : sans garde, `realAssets` bougeait de −24 % (flash loan du natif sur la MetaReserve) ou +24 % (flash loan USDC sur la BaseReserve) sur fork. Une première correction renvoyait `vault.allocation(adapterId)` ; le re-audit a montré qu'elle était contournable : `enterGlobalLock()` n'a **aucun contrôle d'accès**, et le vault ne comptabilise qu'une fois par transaction, donc n'importe qui pouvait figer une valeur périmée choisie par lui, puis racheter ou déposer au mauvais prix. Le verrou est transitoire : le revert ne bloque que la transaction qui le tient. Les deux reserves partagent le verrou de la factory `0x2b2A…0a95`.

Paramètres testés : `exitFeeBps = 15`, `staleHaircutBps = 50`, `staleDecayBpsPerDay = 100`, `minForceDeallocatePenalty = 0,2 %`.

---

## 5. Adapter : allocation et désallocation

Encodage de `data` : allocate `abi.encode(uint256 minMetaLpOut)`, deallocate `abi.encode(uint256 maxMetaLpIn)`.

### 5.1 `allocate`
`meta.depositSingleAsset(BaseLP, assets, this, minMetaLpOut)`, puis rafraîchir le mark, puis renvoyer `change = realAssets − allocation`.

### 5.2 `deallocate`
1. Prendre d'abord le BaseLP idle de l'adapter.
2. Pour le reste : brûler `ceil(metaLp · besoin / (brut · (1 − frais − 5 bps)))` et appeler `withdrawSingleAsset(BaseLP, …, minAmountOut = besoin)`. La marge de 5 bps couvre le frais de spread. Le surplus reste idle et sert à la désallocation suivante.
3. Renvoyer `change = realAssets − assets` (le vault retire `assets` juste après).
4. Appelé par `forceDeallocate` (le vault passe le sélecteur) : revert `ForceDeallocatePenaltyTooLow` si `vault.forceDeallocatePenalty(adapter) < minForceDeallocatePenalty`. Sans ce plancher, un curator qui baisse la pénalité laisserait n'importe qui faire payer le frais de sortie au vault à répétition (audit, finding 4). Le plancher ne peut pas dépasser le maximum Morpho de 2 %, et il ne touche pas aux désallocations de l'allocator.

**Porte fermée : `allocate`, `deallocate` et `forceDeallocate` revertent.** C'est assumé. Les retraits du vault sont alors servis par le BaseLP idle (test `test_vaultExit_servedFromIdle_whenGateClosed`). Le cap relatif de l'adapter fixe la part du vault qui peut être immobilisée.

### 5.3 Paramètres du vault
| Paramètre | Valeur proposée | Raison |
|---|---|---|
| `liquidityAdapter` | Aucun (le BaseLP idle sert de liquidité) | Un adapter gated ferait revert dépôts et retraits 70 % du temps. |
| Cap relatif par MetaReserve | 20 à 40 % ; cap `clear-protocol` 60 à 70 % | Garder assez de BaseLP idle pour les sorties porte fermée. |
| `forceDeallocatePenalty` | ≥ 20 bps (frais 10 + spread + marge) | Sinon `forceDeallocate` fait payer le frais de sortie aux autres. |
| `maxRate` | 15 à 20 % APR | Lisse les gains de dépeg et les remontées après un oracle périmé. |
| Timelocks curator | ≥ 3 j sur `addAdapter`, hausses de caps, `setForceDeallocatePenalty` | Standard pour un collatéral accepté. |

---

## 6. Zap

- `deposit(tokenIn, amountIn, receiver, minShares, swapData)` : tire USDC ou USDT (montant mesuré par écart de solde), `try base.depositSingleAsset`, sinon dépôt équilibré avec achat de l'autre jambe, puis `vault.deposit(BaseLP, receiver)`.
- `redeem(shares, tokenOut, receiver, minAmountOut, swapData)` : `vault.redeem(shares, zap, msg.sender)` (allowance du détenteur requise), `try base.withdrawSingleAsset`, sinon retrait pro rata et vente de l'autre jambe.
- **Deux exécutions pour l'autre jambe**, choisies par `swapData` :
  - **vide** : pool Uniswap V3 USDC/USDT 1 bp (exact-output à l'entrée, exact-input à la sortie). Entièrement on-chain, donc utilisable par un contrat intégrateur qui ne peut pas appeler une API.
  - **non vide** : route KyberSwap construite hors chaîne (`/routes` puis `/route/build`, émetteur et destinataire = le zap), exécutée sur le routeur `MetaAggregationRouterV2` (`0x6131…6b5`, adresse immuable). Meilleure exécution pour la taille (Kyber agrège Fluid, Uniswap v4, Aerodrome, des PropAMMs, etc.). `previewBalancedDeposit` donne le maximum à vendre (plafonné à ce qui reste une fois la jambe `tokenIn` de la reserve mise de côté) et le minimum à recevoir ; `previewBalancedRedeem` donne le montant à vendre. En sortie, la route doit vendre toute la jambe à 1 bp près (`UnsoldLeg` sinon), pour que l'utilisateur reçoive bien le token demandé et qu'une route qui ne vend rien ne passe pas la borne. Le constructeur refuse un routeur sans code. La route n'est pas digne de confiance : allowance exacte remise à zéro après l'appel, résultat mesuré par écart de solde, borne oracle appliquée sur ce qui a réellement été vendu, garde de réentrance. Ignorée quand le chemin single-asset est ouvert.
- **Double borne sur chaque swap** (pas sur le chemin single-asset, qui n'a pas de swap et que seul le `min` de l'utilisateur protège) : le `min` de l'utilisateur, et en interne le cours croisé de l'oracle (prix de marché) moins `maxSwapSlippageBps` (5 bps). Un appel avec `min = 0` reste protégé contre un sandwich au-delà de cette borne. Oracle périmé : la route équilibrée revert, elle ne swappe jamais sur un prix mémorisé.
- Le zap ne garde rien entre deux appels ; la poussière revient à l'appelant.
- Le callback Uniswap n'accepte que le pool configuré ; le constructeur vérifie que ce pool est bien USDC/USDT.

---

## 7. Tests (fork mainnet, bloc 26 299 058)

Fixture : prix poussés en se faisant passer pour le PythOracleAdapter, BaseReserve amorcée à 4 M$, MetaReserve USDS amorcée (1,4 M BaseLP + USDS à 70/30), `VaultV2` neuf en BaseLP. Pour fermer la porte, le fixture déplace d'abord le pool Uniswap hors de la bande, puis aligne l'oracle dessus.

| # | Invariant | Tests |
|---|---|---|
| 7.1 | `realAssets` ne revert jamais | oracle périmé, prix natif invalidé, les deux reserves en pause, invariant fuzzé |
| 7.2 | Valorisation jamais optimiste | formule exacte, ≤ sortie single-asset réelle (snapshot), dépeg du natif, prix > 1 $, invariant fuzzé ≤ borne au pair |
| 7.3 | Coût d'un aller-retour borné | adapter ≤ 2 × frais + 1 bp ; zap single ≤ frais + 1 bp ; zap équilibré ≤ slippage + 5 bps |
| 7.4 | Swap de dépeg : pas de transfert entre déposants | front-runner ≤ `maxRate × durée` |
| 7.5 | `forceDeallocate` ne dilue pas | prix de la part non décroissant |
| 7.6 | Liveness | adapter : revert porte fermée, sorties du vault servies par l'idle ; zap : entrées et sorties USDC/USDT porte fermée |
| 7.7 | `change` suit la position | allocation ≈ `realAssets` après chaque appel ; ids partagés |
| 7.8 | Contrôle d'accès, entrées | vault seul, `data` vide, `maxMetaLpIn`, allowance des parts, tokens refusés, `min` respectés, pool manipulé ⇒ revert |
| 7.9 | Aucune valorisation pendant un appel Clear | `realAssets` et un dépôt dans le vault revertent dans le callback d'un flash loan MetaReserve ou BaseReserve ; prendre le verrou puis comptabiliser et racheter dans la même transaction revert (`FlashLoanPoC.fork.t.sol`, en mode `isolate` pour que chaque appel soit une transaction) |
| 7.10 | Le mark périmé vieillit | décote croissante sur 7 jours puis jambe native à 0, repli sur le dernier prix publié et non sur un `poke` plus ancien, `poke` qui garde l'heure de publication, repli sur le mark de l'adapter si le prix est invalidé |
| 7.11 | Plancher de pénalité `forceDeallocate` | revert sous le plancher, allocator non affecté, constructeur refuse un plancher > 2 % |

| 7.12 | Natif à 6 décimales | toute la suite adapter rejouée sur la MetaReserve PYUSD (`ClearMetaReserveAdapterPyusdForkTest`) |

| 7.13 | Route agrégateur du zap | route honnête à l'entrée et à la sortie ; revert sur mauvais taux, sur tentative de prélever plus que la borne, sur mauvais destinataire, sur réentrance ; `swapData` ignoré si le chemin single-asset est ouvert ; allowance revenue à zéro ; fuzz d'une route vendant exactement `maxSell` dans les deux sens ; revert si la sortie laisse la jambe à moitié vendue ; routeur sans code refusé (`ClearZapAggregator.fork.t.sol`, agrégateur simulé) |
| 7.14 | Vraie route Kyber | sortie équilibrée exécutée sur le vrai routeur avec une route de l'API, en deux passes sur un bloc récent (`ClearZapKyberLive.fork.t.sol`, ignoré par défaut). Le 30/10 au bloc 26 304 454 : 49 969 USDT vendus via Aerodrome CL et deux PropAMMs, 2,6 bps de coût total sur la sortie |

Résultat au 30/10 : 84 tests fork (dont 29 sur PYUSD) et 5 tests d'invariants (32 runs × 40 appels) passent ; le test live Kyber passe quand il est lancé à la main.

---

## 8. Risques et points ouverts

1. **Immobilisation de l'adapter ~70 % du temps** (porte USDT). C'est le point principal pour les intégrateurs. Leviers côté Clear : élargir `redemptionProximityBps` (c'est un paramètre de sécurité, à faire auditer), ou ajouter une sortie équilibrée côté MetaReserve vers un BaseLP seul.
2. **Frais et prix de rachat modifiables sans délai** par la Safe Admin. Ajouter un délai AccessManager au moins égal au timelock curator du vault.
3. **Oracle périmé** : la jambe native perd 50 bps × son poids (~15 bps de la position) dès la première heure, puis 100 bps par jour en plus, jusqu'à zéro. Quand l'oracle revient, la remontée se fait au rythme de `maxRate` : une panne longue coûte donc longtemps aux déposants, même si le natif n'a pas bougé. C'est voulu (on ne valorise pas un actif qu'on ne voit plus), mais `staleDecayBpsPerDay` est le paramètre à discuter avec le curateur. Un déposant entré pendant la fenêtre capte une partie de la remontée, borné par `maxRate`.
4. **Marge de désallocation de 5 bps** : si le frais de spread la dépasse, `deallocate` revert et il faut réessayer avec un montant plus petit.
5. **Qualification réglementaire** du vault et du rôle de curateur, à établir avant le lancement.
6. **Deux passes de revue IA, audit externe à faire.** Première passe `/solidity-auditor deep` (29/10) : findings 1 et 2 (flash loans, confirmés sur fork), 3 (âge du mark) et 4 (plancher de pénalité `forceDeallocate`) corrigés. Deuxième passe sur le code corrigé : la correction du finding 1 était contournable (verrou Clear ouvert à tous, [90]), corrigée par un revert ; l'âge du mark partait du `poke` et non de la publication ([60]), corrigé ; garde anti-underflow ajoutée sur l'âge. Écarté après vérification : forcer le `catch` de l'oracle par limitation de gas (le 1/64 restant ne suffit pas à finir l'appel au vault). L'oracle reste `immutable` : un changement d'oracle Clear impose un nouvel adapter. Corrigés avec l'ajout de Kyber : montant reçu mesuré (USDT avec frais de transfert), pool Uniswap validé au constructeur. Restent ouverts, sous le seuil de confiance : une `data` à double sens, la marge de 5 bps, le mélange des jambes via un swap MetaReserve en dépeg, l'arrondi du dépôt équilibré du zap, l'absence de deadline sur le zap, la poussière reversée au prochain appelant. Troisième passe `/solidity-auditor deep` sur le zap avec la route Kyber (30/10) : une route vendant exactement le `maxSell` documenté faisait revert le dépôt dans environ 73 % des cas, à 1-3 wei près ([75], reproduit par un fuzz puis corrigé) ; une sortie pouvait laisser la jambe invendue ([50], corrigé) ; routeur sans code (corrigé) ; commentaire de borne précisé. Vérifié sans finding : une route ne peut dépenser ni les allowances d'autres utilisateurs, ni les approbations max du zap à la BaseReserve et au vault (elles prélèvent toutes sur `msg.sender`). Restent ouverts : une route construite sur un aperçu peut être invalidée par une petite opération sur la reserve juste avant (revert, pas de perte) ; l'aperçu de dépôt n'est pas recalculé si la route passe elle-même par Clear (revert ou poussière pour l'appelant). Un audit externe ciblé (adapter + zap, environ 480 lignes) reste nécessaire avant tout déploiement.
