# Cloud Run service for the LiteLLM gateway plus its A2A auth sidecar.
# Rendered by deploy/gcp/render.py and applied with `gcloud run services replace`.
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: litellm
  labels:
    app: secure-gpt
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/minScale: "${LITELLM_MIN_INSTANCES:-0}"
        autoscaling.knative.dev/maxScale: "${LITELLM_MAX_INSTANCES:-5}"
        run.googleapis.com/cloudsql-instances: "${SQL_CONN}"
        run.googleapis.com/execution-environment: gen2
    spec:
      serviceAccountName: "${SA_EMAIL}"
      containerConcurrency: 40
      timeoutSeconds: 900
      containers:
        # The gateway. Only this container is reachable on the service port.
        - name: litellm
          image: "${LITELLM_IMAGE}"
          args: ["--config", "/etc/litellm/config.yaml", "--port", "8080", "--num_workers", "2"]
          ports:
            - name: http1
              containerPort: 8080
          resources:
            limits:
              cpu: "2"
              memory: 4Gi
          env:
            - name: DATABASE_URL
              value: "postgresql://securegpt:${POSTGRES_PASSWORD}@/litellm?host=/cloudsql/${SQL_CONN}"
            - name: LITELLM_MASTER_KEY
              valueFrom:
                secretKeyRef: { name: secure-gpt-litellm-master-key, key: latest }
            - name: LITELLM_SALT_KEY
              valueFrom:
                secretKeyRef: { name: secure-gpt-litellm-salt-key, key: latest }
            - name: UI_USERNAME
              value: admin
            - name: UI_PASSWORD
              valueFrom:
                secretKeyRef: { name: secure-gpt-litellm-ui-password, key: latest }
            - name: GEMINI_API_KEY
              valueFrom:
                secretKeyRef: { name: secure-gpt-gemini-api-key, key: latest }
            # Vertex: ADC comes from the runtime service account, so there is
            # no credentials file to mount.
            - name: VERTEX_PROJECT
              value: "${GCP_PROJECT}"
            - name: VERTEX_LOCATION
              value: "${VERTEX_LOCATION:-eu}"
            - name: VERTEX_EMBED_LOCATION
              value: "${VERTEX_EMBED_LOCATION:-europe-west1}"
            - name: GOOGLE_CLOUD_PROJECT
              value: "${GCP_PROJECT}"
            - name: DO_NOT_TRACK
              value: "1"
            - name: LITELLM_DONT_SHOW_FEEDBACK_BOX
              value: "true"
          volumeMounts:
            - name: litellm-config
              mountPath: /etc/litellm
          startupProbe:
            httpGet: { path: /health/liveliness, port: 8080 }
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 30
          livenessProbe:
            httpGet: { path: /health/liveliness, port: 8080 }
            periodSeconds: 60

        # Attaches a fresh Google token to A2A calls bound for Agent Runtime.
        # Listens on localhost only, so nothing outside the instance can use it.
        - name: a2a-shim
          image: "${SHIM_IMAGE}"
          resources:
            limits:
              cpu: "1"
              memory: 512Mi
          env:
            - name: AGENT_ENGINE_RESOURCE
              value: "${AGENT_ENGINE_RESOURCE:-}"
            - name: AGENT_APP_NAME
              value: "${AGENT_APP_NAME:-weather_time_agent}"
            - name: AGENT_ENGINE_LOCATION
              value: "${AGENT_ENGINE_LOCATION:-europe-west1}"
            - name: PORT
              value: "8081"
      volumes:
        - name: litellm-config
          secret:
            secretName: secure-gpt-litellm-config
            items:
              - key: latest
                path: config.yaml
  traffic:
    - percent: 100
      latestRevision: true
