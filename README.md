## Private network using QBFT on Hyperledger Besu

**Script for creating a QBFT network on Hyperledger Besu using Docker.**
**Includes options for using post quantum cryptography (Dilithium, Sphincs and Falcon).**


## Prerequisites

- `docker-compose`
- `Besu Image`


## Usage

- Clone repo
- `cd besu-qbft-private-network`
- `chmod +x init-qbft.sh`
- You need to know the name of the besu image. Replace ***hyperledger/besu*** with your image name
- `./init-qbft.sh hyperledger/besu`
- For images with PQC support, made by Venturus:
- `./init-qbft.sh hyperledger/besu:pqc dilithium`
- Use your image name instead of hyperledger/besu:pqc.
- It's possible to select pqc parameter by index.
- `./init-qbft.sh hyperledger/besu:pqc dilithium 1`
- replace `1` with the desired parameter index. For more details, see the list bellow.


## Parameter Specs

#### Dilithium Parameter Specs
| Index | Spec |
|-------|------|
|0|dilithium2|
|1|dilithium2|
|2|dilithium2|

#### Falcon Parameter Specs
| Index | Spec |
|-------|------|
|0|falcon_512|
|1|falcon_1024|

#### Sphincs Plus Parameter Specs
| Index | Spec |
|-------|------|
|0|sha2_128f|
|1|sha2_128f_simple|
|2|sha2_128s|
|3|sha2_128s_simple|
|4|sha2_192f|
|5|sha2_192f_simple|
|6|sha2_192s|
|7|sha2_192s_simple|
|8|sha2_256f|
|9|sha2_256f_simple|
|10|sha2_256s|
|11|sha2_256s_simple|
|12|shake_128f|
|13|shake_128f_simple|
|14|shake_128s|
|15|shake_128s_simple|
|16|shake_192f|
|17|shake_192f_simple|
|18|shake_192s|
|19|shake_192s_simple|
|20|shake_256f|
|21|shake_256f_simple|
|22|shake_256s|
|23|shake_256s_simple|






