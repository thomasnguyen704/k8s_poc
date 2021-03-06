from pyspark.sql import SparkSession, DataFrame
from typing import List
import sys
from streamstate_utils.firestore import get_firestore_inputs_from_config_map

# from streamstate_utils.cassandra_utils import (
#    get_cassandra_inputs_from_config_map,
#    get_cassandra_outputs_from_config_map,
# )

from streamstate_utils.generic_wrapper import (
    file_wrapper,
    write_wrapper,
    write_firestore,
    # set_cassandra,
    # write_cassandra,
    write_kafka,
)
from streamstate_utils.structs import (
    OutputStruct,
    FileStruct,
    # CassandraInputStruct,
    # CassandraOutputStruct,
    KafkaStruct,
    InputStruct,
    TableStruct,
    FirestoreOutputStruct,
)

from process import process
import json
import os


def replay_from_file(
    app_name: str,
    bucket: str,
    inputs: List[InputStruct],
    output: OutputStruct,
    files: FileStruct,
    table: TableStruct,
    firestore: FirestoreOutputStruct,
    kafka: KafkaStruct,
    checkpoint_location: str,
):
    spark = SparkSession.builder.appName(app_name).getOrCreate()
    # set_cassandra(cassandra_input, spark)
    df = file_wrapper(app_name, files.max_file_age, bucket, process, inputs, spark)

    def dual_write(batch_df: DataFrame):
        batch_df.persist()
        # todo, uncomment this
        # write_kafka(batch_df, kafka, output)
        write_firestore(batch_df, firestore, table)

    # print(os.path.join(bucket, checkpoint_location, app_name))
    # os.path.join(bucket, checkpoint_location, app_name)
    write_wrapper(
        df, output, os.path.join(bucket, checkpoint_location, app_name), dual_write
    )


# examples
# mode = "append"
# schema = [
#     (
#         "topic1",
#         {
#             "fields": [
#                 {"name": "first_name", "type": "string"},
#                 {"name": "last_name", "type": "string"},
#             ]
#         },
#     )
# ]

if __name__ == "__main__":
    [
        _,
        app_name,
        bucket,  # bucket name including gs://
        table_struct,
        output_struct,
        file_struct,
        kafka_struct,
        input_struct,
        checkpoint_location,
        version,
    ] = sys.argv
    output_info = OutputStruct(**json.loads(output_struct))
    file_info = FileStruct(**json.loads(file_struct))
    table_info = TableStruct(**json.loads(table_struct))
    firestore = get_firestore_inputs_from_config_map(app_name, version)

    kafka_info = KafkaStruct(**json.loads(kafka_struct))
    input_info = [InputStruct(**v) for v in json.loads(input_struct)]
    replay_from_file(
        app_name,
        bucket,
        input_info,
        output_info,
        file_info,
        table_info,
        firestore,
        kafka_info,
        checkpoint_location,
    )
