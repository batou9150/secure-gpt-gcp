# Open WebUI on Cloud Run, with an auth-proxy sidecar.
#
# This organization forbids allUsers on Cloud Run, so the gateway is
# IAM-protected and callers must present an identity token. Open WebUI cannot
# mint one, so it talks to http://localhost:4000 and the sidecar signs the
# call with the runtime service account.
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: open-webui
  labels:
    app: secure-gpt
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "${OPENWEBUI_MIN_INSTANCES:-0}"
        autoscaling.knative.dev/maxScale: "${OPENWEBUI_MAX_INSTANCES:-5}"
        run.googleapis.com/cloudsql-instances: "${SQL_CONN}"
        run.googleapis.com/execution-environment: gen2
        run.googleapis.com/container-dependencies: '{"open-webui":["auth-proxy"]}'
    spec:
      serviceAccountName: "${SA_EMAIL}"
      containerConcurrency: 40
      timeoutSeconds: 900
      containers:
        - name: open-webui
          image: "${OPENWEBUI_IMAGE}"
          ports:
            - name: http1
              containerPort: 8080
          resources:
            limits:
              cpu: "2"
              memory: 4Gi
          env:
            - name: DATABASE_URL
              value: "postgresql://securegpt:${POSTGRES_PASSWORD}@localhost/openwebui?host=/cloudsql/${SQL_CONN}"
            - name: WEBUI_SECRET_KEY
              valueFrom:
                secretKeyRef: { name: secure-gpt-openwebui-secret-key, key: latest }
            # The gateway is reached through the sidecar, never directly.
            - name: OPENAI_API_BASE_URL
              value: "http://localhost:4000/v1"
            - name: OPENAI_API_KEY
              value: "${OPENWEBUI_CHAT_KEY}"
            - name: RAG_OPENAI_API_BASE_URL
              value: "http://localhost:4000/v1"
            - name: RAG_OPENAI_API_KEY
              value: "${OPENWEBUI_EMBED_KEY}"
            - name: RAG_EMBEDDING_ENGINE
              value: openai
            - name: RAG_EMBEDDING_MODEL
              value: "${EMBEDDING_MODEL:-gemini-embedding-001}"
            - name: ENABLE_OPENAI_API
              value: "True"
            - name: ENABLE_OLLAMA_API
              value: "False"
            - name: ENABLE_DIRECT_CONNECTIONS
              value: "False"
            - name: ENABLE_EVALUATION_ARENA_MODELS
              value: "False"
            - name: ENABLE_WEB_SEARCH
              value: "False"
            - name: ENABLE_IMAGE_GENERATION
              value: "False"
            - name: ENABLE_COMMUNITY_SHARING
              value: "False"
            - name: ENABLE_AUTOCOMPLETE_GENERATION
              value: "False"
            - name: ENABLE_ADMIN_CHAT_ACCESS
              value: "False"
            - name: ENABLE_ADMIN_EXPORT
              value: "False"
            - name: DEFAULT_USER_ROLE
              value: pending
            - name: WEBUI_AUTH
              value: "True"
            - name: WEBUI_NAME
              value: "Secure GPT"
            - name: WEBUI_SESSION_COOKIE_SAME_SITE
              value: strict
            - name: WEBUI_SESSION_COOKIE_SECURE
              value: "True"
            - name: AUDIO_STT_ENGINE
              value: ""
            - name: ANONYMIZED_TELEMETRY
              value: "False"
            - name: DO_NOT_TRACK
              value: "1"
            - name: SCARF_NO_ANALYTICS
              value: "True"
            - name: ENABLE_VERSION_UPDATE_CHECK
              value: "False"
          startupProbe:
            httpGet: { path: /health, port: 8080 }
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 40

        - name: auth-proxy
          image: "${SHIM_IMAGE}"
          resources:
            limits:
              cpu: "1"
              memory: 512Mi
          env:
            - name: MODE
              value: cloudrun
            - name: UPSTREAM_URL
              value: "${GCP_LITELLM_URL}"
            - name: PORT
              value: "4000"
          startupProbe:
            httpGet: { path: /healthz, port: 4000 }
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 20
  traffic:
    - percent: 100
      latestRevision: true
