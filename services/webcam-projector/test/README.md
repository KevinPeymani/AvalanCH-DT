Exemples rapides

1. Variables d'environnement RabbitMQ :

```bash
export RABBITMQ_URL=amqp://guest:guest@localhost:5672/
export RABBITMQ_INPUT_QUEUE=detector.result
export RABBITMQ_OUTPUT_QUEUE=projection.result
export SERVICE_NAME=webcam-projector
```

2. Lancer le service :

```bash
python -m app.main --config config/dev.yaml
```

3. Publier un faux message avec un YAML caméra :

```bash
python -m app.publish /path/to/blauherd.yaml
```
