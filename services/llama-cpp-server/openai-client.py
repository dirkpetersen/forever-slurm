#!/usr/bin/env python3

import os, sys, openai

streaming=True

if len(sys.argv) < 3:
    print(f"Usage: {sys.argv[0]} <http://server:port/v1> <prompt>")
    sys.exit(1)

openai_url = sys.argv[1]
prompt = sys.argv[2]

client = openai.OpenAI(
    base_url=openai_url,
    api_key=os.getenv('OPENAI_API_KEY', os.getenv('USER') or os.getenv('USERNAME')),
)

def get_openai_response(client, prompt, streaming):
    try:
        response = client.chat.completions.create(
            messages=[
                {
                    "role": "user",
                    "content": prompt,
                }
            ],
            model="whatever",
            stream=streaming
        )
        # Process the stream
        if streaming:
            full_response = ""
            for chunk in response:
                chunk_message = chunk.choices[0].delta.content
                if chunk_message:
                    full_response += chunk_message
                    print(chunk_message, end='', flush=True)

            print()  # Print a newline after streaming is complete
            return full_response
        else:
            return response.choices[0].message.content
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return None

response = get_openai_response(client, prompt, streaming)
if not streaming: 
    print(response)


