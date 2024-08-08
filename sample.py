import os
import json
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

endpoint = os.environ["COSMOS_ENDPOINT"]
database_name = "sample"
container_name = "sample-container"

# Using ClientSecretCredential
credential = DefaultAzureCredential() # DefaultAzureCredential will use the VM managed identity to connect to Azure Cosmos DB
client = CosmosClient(url=endpoint, credential=credential)

database = client.get_database_client(database_name)
container = database.get_container_client(container_name)

new_item = {
    "id": "Product1",
    "categoryId": "61dba35b-4f02-45c5-b648-c6badc0cbd79",
    "categoryName": "eletronics",
    "name": "Surface Laptop",
    "quantity": 12,
    "sale": True,
}

container.upsert_item(new_item)

existing_item = container.read_item(
    item="Product1",
    partition_key="Product1",
)
print("Point read\t", existing_item)


QUERY = "SELECT * FROM p WHERE p.categoryName = @categoryName"
CATEGORYNAME = "eletronics"
params = [dict(name="@categoryName", value=CATEGORYNAME)]

results = container.query_items(
    query=QUERY, parameters=params, enable_cross_partition_query=True
)

items = [item for item in results]
output = json.dumps(items, indent=True)
print("Result list\t", output)