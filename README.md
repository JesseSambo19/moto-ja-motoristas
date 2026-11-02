# MotoJá Motoqueiro

Aplicação Flutter independente para motoqueiros de moto-táxi. O código do motoqueiro fica em `moto_ja_motorista/`; a aplicação de passageiros em `moto_ja/` não foi alterada.

## Requisitos

- Flutter e Dart compatíveis com `pubspec.yaml`.
- API Laravel em `backend/`, com as migrações aplicadas.
- Conta provisionada na base de dados com `role=driver`, `vehicle_type=moto` e dados da motocicleta. O registo público cria apenas contas de passageiros.

## Executar

Na pasta `moto_ja_motorista/`:

```sh
flutter pub get
flutter run
```

Os URLs estão centralizados em `lib/utils/app_urls.dart`. Para desenvolvimento,
`API_URL` e `STORAGE_URL` usam o emulador Android e a porta `8001`, porque a
porta `8000` está ocupada por outro projeto Laravel neste workspace. Para
Web/desktop, troca `10.0.2.2` por `127.0.0.1`; num telemóvel físico, usa o IP
local do computador. Altera `API_URL` e `STORAGE_URL` juntos.

Quando estiveres pronto para produção, comenta as duas linhas de
desenvolvimento e descomenta/substitui as linhas de produção no mesmo ficheiro.
`ROUTING_URL` aponta para o OSRM público para demonstrações; substitui-o por um
serviço de routing gerido para produção. `STORAGE_URL` está preparado para uso
futuro e ainda não é usado pela app.

## Conta de demonstração

Conta de motoqueiro criada na base de dados local configurada para demonstrações:

- **Telefone:** `+244900000123`
- **Palavra-passe:** `MotoJaDemo2026!`
- **Veículo:** Moto · Demo Motorcycle · matrícula `DEMO-001`

Usa estas credenciais no ecrã de entrada do motoqueiro. Esta conta depende da base
de dados local onde foi criada e não deve ser usada num ambiente de produção.

## Funcionalidades

- Interface em português, autenticação de motoqueiro e token guardado com `flutter_secure_storage`.
- Estado online/offline, permissão de localização e envio da posição enquanto a aplicação está aberta.
- Pedidos de moto-táxi próximos atualizados por polling a cada 2 segundos, com aviso quando chega um novo pedido.
- Aceitação do pedido, mapa com posição do motoqueiro, recolha e destino, rota rodoviária, instruções por voz em português, recálculo ao sair da rota, Google Maps externo e chamada ao passageiro.
- Etapas da viagem: chegar ao ponto de recolha, iniciar e concluir. Uma viagem ativa é recuperada depois de reiniciar a aplicação.
- Resumo de tarifas brutas e viagens concluídas no dia, além das cinco viagens concluídas mais recentes.

## Limites atuais

- O resumo apresenta o valor bruto das tarifas. Comissão, carteira, levantamentos, bónus e pagamentos não existem na API.
- O routing usa o perfil rodoviário `driving` do OSRM. O servidor público predefinido serve para desenvolvimento/demonstração; para produção comercial, substitui `ROUTING_URL` em `lib/utils/app_urls.dart` por uma instância OSRM gerida por ti ou um fornecedor contratado. As rotas não incluem trânsito em tempo real e o perfil de automóvel não conhece restrições específicas de moto.
- A voz usa as vozes portuguesas instaladas no dispositivo (pt-PT, com fallback pt-BR). A voz funciona nas aplicações Android e iOS; Web/desktop mantém o mapa e a opção de abrir o Google Maps.
- Localização e pedidos são atualizados enquanto a aplicação está aberta. Rastreamento em segundo plano e notificações push ainda não estão configurados.
- Cadastro, verificação de documentos, suporte do parceiro e ferramentas de segurança dependem de serviços/backend ainda não implementados.
- Não há mapa de calor nem previsão de zonas de procura; a aplicação mostra os pedidos abertos devolvidos pela API.
