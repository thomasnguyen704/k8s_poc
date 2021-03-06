from typing import List, Callable, Optional, Dict, Union

from fastapi import FastAPI, HTTPException, Header, Query
from pydantic import BaseModel
from streamstate_utils.structs import (
    FileStruct,
    InputStruct,
    KafkaStruct,
    OutputStruct,
    TableStruct,
)


app = FastAPI(openapi_url="/docs/openapi.json")
import os
from streamstate_utils.firestore import (
    get_collection_from_org_name_and_app_name,
    get_document_name_from_version_and_keys,
    open_firestore_connection,
)
from streamstate_utils.k8s_utils import (
    get_organization_from_config_map,
    get_project_from_config_map,
)


from kubernetes import client, config
from kubernetes.client.rest import ApiException

# Configs can be set in Configuration class directly or using helper utility
config.load_incluster_config()
V1 = client.CoreV1Api()
CUSTOM_OBJECT = client.CustomObjectsApi()
ORGANIZATION = get_organization_from_config_map()
PROJECT_ID = get_project_from_config_map()
DB = open_firestore_connection(PROJECT_ID)
NAMESPACE = os.getenv("NAMESPACE", "")
## if, for example, the data is account_id, count_logins_last_30_days
## with account_id being the primary key, then this would get the most
## recent data for this account_id
def get_latest_record(
    db, org_name: str, app_name: str, version: int, key_values: List[str]
) -> dict:
    """
    Gets latest record by key

    Attributes:
    db: instance of firestore client
    org_name: name of organization
    app_name: name of app
    version: schema version
    key_values: the values of the primary key columns.
    Must be in the same order as on write
    """
    collection = get_collection_from_org_name_and_app_name(org_name, app_name)
    document = get_document_name_from_version_and_keys(key_values, version)

    return db.collection(collection).document(document).get().to_dict()


def check_auth_head(authorization: str) -> bool:
    return authorization.startswith("Bearer ")


def check_auth(authorization: str, actual_token: str) -> bool:
    token = authorization.replace("Bearer ", "")
    return token == actual_token


def get_write_token() -> str:
    return open("/etc/secret-volume/write_token/token", "r").read()


def get_read_token() -> str:
    return open("/etc/secret-volume/read_token/token", "r").read()


def auth_checker(authorization: Optional[str], get_token: Callable[[], str]):
    if authorization is None:
        raise HTTPException(status_code=401, detail="Authorization header required")

    if not check_auth_head(authorization):
        raise HTTPException(status_code=401, detail="Malformed authorization header")

    actual_token = get_token()
    if not check_auth(authorization, actual_token):
        raise HTTPException(status_code=401, detail="Incorrect token")


@app.post("/api/{app_name}/stop")
def stop_spark_job(app_name: str, authorization: Optional[str] = Header(None)):
    auth_checker(authorization, get_write_token)
    try:
        api_response = CUSTOM_OBJECT.delete_namespaced_custom_object(
            "sparkoperator.k8s.io",
            "v1beta2",
            NAMESPACE,
            "sparkapplications",
            app_name,
            body=client.V1DeleteOptions(),
        )
        return api_response
    except ApiException as e:
        raise HTTPException(status_code=e.status, detail=e.body)


@app.get("/api/{app_name}/features/{version}")
def read_feature(
    app_name: str,
    version: int,
    filter: Optional[List[str]] = Query(None),
    authorization: Optional[str] = Header(None),
):
    auth_checker(authorization, get_read_token)
    if filter is None:
        raise HTTPException(status_code=400, detail="Query parameter filter required")
    return get_latest_record(DB, ORGANIZATION, app_name, version, filter)


class ApiDeploy(BaseModel):
    pythoncode: str
    inputs: List[InputStruct]
    assertions: List[Dict[str, Union[str, float, int, bool]]]
    kafka: KafkaStruct
    outputs: OutputStruct
    table: TableStruct
    fileinfo: FileStruct
    appname: str

    class Config:
        schema_extra = {
            "example": {
                "pythoncode": "ZnJvbSB0eXBpbmcgaW1wb3J0IExpc3QKZnJvbSBweXNwYXJrLnNxbCBpbXBvcnQgRGF0YUZyYW1lCgoKZGVmIHByb2Nlc3MoZGZzOiBMaXN0W0RhdGFGcmFtZV0pIC0+IERhdGFGcmFtZToKICAgIHJldHVybiBkZnNbMF0K",
                "inputs": [
                    {
                        "topic": "topic1",
                        "sample": [{"field1": "somevalue"}],
                        "topic_schema": [{"name": "field1", "type": "string"}],
                    }
                ],
                "assertions": [{"field1": "somevalue"}],
                "kafka": {"brokers": "broker1,broker2"},
                "outputs": {"mode": "append", "processing_time": "2 seconds"},
                "fileinfo": {"max_file_age": "2d"},
                "table": {
                    "primary_keys": ["field1"],
                    "output_schema": [{"name": "field1", "type": "string"}],
                },
                "appname": "mytestapp",
            }
        }


## this is a dummy endpoint, to
## add docs to the argo webhook
## endpoint.  This never gets
## called because our ingress
## redirects api/deploy to argo
@app.post("/api/deploy")
def create_spark_streaming_job(
    body: ApiDeploy,
    authorization: Optional[str] = Header(None),
):
    return "success"
