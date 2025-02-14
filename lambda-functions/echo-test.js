exports.handler = async (event) => {
  // Log the incoming event for debugging
  console.log('Received event:', JSON.stringify(event, null, 2));

  // Prepare response with the event data
  const response = {
    statusCode: 200,
    body: JSON.stringify({
      message: 'Echo response',
      input: event
    }, null, 2)
  };

  console.log('Returning response:', JSON.stringify(response, null, 2));
  return response;
};
